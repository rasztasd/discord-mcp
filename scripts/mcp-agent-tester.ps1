[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('init', 'list-tools', 'call-tool', 'ping', 'show-session', 'close')]
    [string]$Action = 'list-tools',
    [string]$Endpoint = 'http://localhost:8085/mcp',
    [string]$ToolName,
    [string]$ArgumentsJson,
    [string]$ArgumentsFile,
    [string]$SessionFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'discord-mcp-session.json'),
    [string]$ProtocolVersion = '2025-11-25',
    [string]$ClientName = 'discord-mcp-agent-tester',
    [string]$ClientVersion = '0.1.0',
    [int]$TimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:HttpClient = [System.Net.Http.HttpClient]::new()
$script:HttpClient.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

function New-McpRequestId {
    param([string]$Prefix)
    '{0}-{1}' -f $Prefix, ([Guid]::NewGuid().ToString('N'))
}

function Get-McpHeaderValue {
    param([hashtable]$Headers, [string]$Name)
    foreach ($Key in $Headers.Keys) {
        if ($Key -ieq $Name) { return [string]$Headers[$Key] }
    }
    $null
}

function Invoke-McpHttp {
    param([string]$Method, [string]$Url, [hashtable]$Headers, [string]$Body)

    $Request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Url)
    if ($null -ne $Body) {
        $Request.Content = [System.Net.Http.StringContent]::new($Body, [System.Text.Encoding]::UTF8, 'application/json')
    }

    foreach ($Pair in $Headers.GetEnumerator()) {
        if (($Pair.Key -ieq 'Accept')) {
            foreach ($MediaType in ([string]$Pair.Value -split ',')) {
                $Trimmed = $MediaType.Trim()
                if ($Trimmed) { $null = $Request.Headers.Accept.ParseAdd($Trimmed) }
            }
            continue
        }

        if (($Pair.Key -ieq 'Content-Type') -and ($null -ne $Request.Content)) {
            $Request.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse([string]$Pair.Value)
            continue
        }

        if (-not $Request.Headers.TryAddWithoutValidation($Pair.Key, [string]$Pair.Value)) {
            if ($null -eq $Request.Content) {
                throw "Cannot add header '$($Pair.Key)' without request content."
            }
            $null = $Request.Content.Headers.TryAddWithoutValidation($Pair.Key, [string]$Pair.Value)
        }
    }

    $Response = $script:HttpClient.SendAsync($Request).GetAwaiter().GetResult()
    $ResponseHeaders = @{}
    foreach ($Header in $Response.Headers) {
        $ResponseHeaders[$Header.Key] = ($Header.Value -join ', ')
    }
    if ($null -ne $Response.Content) {
        foreach ($Header in $Response.Content.Headers) {
            $ResponseHeaders[$Header.Key] = ($Header.Value -join ', ')
        }
    }

    [pscustomobject]@{
        StatusCode = [int]$Response.StatusCode
        Headers    = $ResponseHeaders
        Body       = if ($null -ne $Response.Content) { $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult() } else { '' }
    }
}

function ConvertFrom-McpSse {
    param([string]$Text)

    $Messages = New-Object System.Collections.ArrayList
    $EventName = $null
    $EventId = $null
    $DataLines = New-Object System.Collections.Generic.List[string]

    function Flush-Event {
        if (($DataLines.Count -eq 0) -and [string]::IsNullOrWhiteSpace($EventName) -and [string]::IsNullOrWhiteSpace($EventId)) {
            return
        }

        $Data = ($DataLines -join "`n")
        $Json = $null
        if ($Data) { $Json = $Data | ConvertFrom-Json -Depth 100 }
        $null = $Messages.Add([pscustomobject]@{ event = $EventName; id = $EventId; data = $Data; json = $Json })
    }

    foreach ($Line in ($Text -split "`r?`n")) {
        if ($Line -eq '') {
            Flush-Event
            $EventName = $null
            $EventId = $null
            $DataLines = New-Object System.Collections.Generic.List[string]
            continue
        }
        if ($Line.StartsWith(':')) { continue }
        $Index = $Line.IndexOf(':')
        if ($Index -lt 0) { continue }
        $Field = $Line.Substring(0, $Index)
        $Value = $Line.Substring($Index + 1)
        if ($Value.StartsWith(' ')) { $Value = $Value.Substring(1) }
        switch ($Field) {
            'event' { $EventName = $Value }
            'id' { $EventId = $Value }
            'data' { $null = $DataLines.Add($Value) }
        }
    }

    Flush-Event
    @($Messages.ToArray())
}

function ConvertFrom-McpResponse {
    param([pscustomobject]$Response)

    $ContentType = (Get-McpHeaderValue -Headers $Response.Headers -Name 'Content-Type')
    $Normalized = if ($ContentType) { $ContentType.ToLowerInvariant() } else { '' }

    if ($Normalized.Contains('application/json')) {
        if ([string]::IsNullOrWhiteSpace($Response.Body)) { return @() }
        return @($Response.Body | ConvertFrom-Json -Depth 100)
    }

    if ($Normalized.Contains('text/event-stream')) {
        return @(ConvertFrom-McpSse -Text $Response.Body | ForEach-Object { $_.json } | Where-Object { $null -ne $_ })
    }

    if ([string]::IsNullOrWhiteSpace($Response.Body)) { return @() }
    throw "Unsupported response content type: $ContentType"
}

function ConvertTo-PrettyJson {
    param([object]$Value)
    $Value | ConvertTo-Json -Depth 100
}

function Write-McpFailure {
    param([string]$Message, [pscustomobject]$Response)
    if ([string]::IsNullOrWhiteSpace($Response.Body)) { throw $Message }
    throw ($Message + "`n" + $Response.Body)
}

function Load-McpSession {
    if (-not (Test-Path -LiteralPath $SessionFile)) { return $null }
    $Raw = Get-Content -LiteralPath $SessionFile -Raw
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    $Raw | ConvertFrom-Json -Depth 100
}

function Save-McpSession {
    param([string]$SessionId, [object]$InitializeResult)

    $Directory = Split-Path -Parent $SessionFile
    if ($Directory) { $null = New-Item -ItemType Directory -Path $Directory -Force }

    $State = [ordered]@{
        endpoint        = $Endpoint
        sessionId       = $SessionId
        protocolVersion = $InitializeResult.protocolVersion
        serverInfo      = $InitializeResult.serverInfo
        clientName      = $ClientName
        clientVersion   = $ClientVersion
        createdAt       = (Get-Date).ToString('o')
    }

    Set-Content -LiteralPath $SessionFile -Value (ConvertTo-PrettyJson -Value $State) -Encoding UTF8
    [pscustomobject]$State
}

function Remove-McpSessionFile {
    if (Test-Path -LiteralPath $SessionFile) {
        Remove-Item -LiteralPath $SessionFile -Force
    }
}
function Get-PostHeaders {
    param([string]$SessionId)
    $Headers = @{
        'Accept'               = 'application/json, text/event-stream'
        'Content-Type'         = 'application/json'
        'Cache-Control'        = 'no-cache'
        'MCP-Protocol-Version' = $ProtocolVersion
    }
    if ($SessionId) { $Headers['Mcp-Session-Id'] = $SessionId }
    $Headers
}

function Get-DeleteHeaders {
    param([string]$SessionId)
    @{
        'Cache-Control'        = 'no-cache'
        'MCP-Protocol-Version' = $ProtocolVersion
        'Mcp-Session-Id'       = $SessionId
    }
}

function Start-McpSession {
    $InitId = New-McpRequestId -Prefix 'initialize'
    $InitPayload = @{
        jsonrpc = '2.0'
        id      = $InitId
        method  = 'initialize'
        params  = @{
            protocolVersion = $ProtocolVersion
            capabilities    = @{}
            clientInfo      = @{ name = $ClientName; version = $ClientVersion }
        }
    }

    $InitResponse = Invoke-McpHttp -Method 'POST' -Url $Endpoint -Headers (Get-PostHeaders) -Body (($InitPayload | ConvertTo-Json -Depth 100 -Compress))
    if (($InitResponse.StatusCode -lt 200) -or ($InitResponse.StatusCode -ge 300)) {
        Write-McpFailure -Message 'MCP initialize failed.' -Response $InitResponse
    }

    $Envelope = ConvertFrom-McpResponse -Response $InitResponse
    if ($Envelope.Count -ne 1) { throw 'Unexpected initialize response envelope.' }
    $InitMessage = $Envelope[0]
    if ($null -ne $InitMessage.error) {
        throw ('Initialize JSON-RPC error: ' + ($InitMessage.error | ConvertTo-Json -Depth 20 -Compress))
    }

    $SessionId = Get-McpHeaderValue -Headers $InitResponse.Headers -Name 'Mcp-Session-Id'
    if (-not $SessionId) { throw 'Initialize succeeded but no Mcp-Session-Id header was returned.' }

    $ReadyPayload = @{ jsonrpc = '2.0'; method = 'notifications/initialized'; params = $null }
    $ReadyResponse = Invoke-McpHttp -Method 'POST' -Url $Endpoint -Headers (Get-PostHeaders -SessionId $SessionId) -Body (($ReadyPayload | ConvertTo-Json -Depth 100 -Compress))
    if (($ReadyResponse.StatusCode -lt 200) -or ($ReadyResponse.StatusCode -ge 300)) {
        Write-McpFailure -Message 'notifications/initialized failed.' -Response $ReadyResponse
    }

    Save-McpSession -SessionId $SessionId -InitializeResult $InitMessage.result
}

function Ensure-McpSession {
    param([switch]$ForceRefresh)

    if (-not $ForceRefresh) {
        $Existing = Load-McpSession
        if (($null -ne $Existing) -and ($Existing.endpoint -eq $Endpoint) -and $Existing.sessionId) {
            return $Existing
        }
    }

    Start-McpSession
}

function Invoke-McpJsonRpc {
    param([string]$Method, [object]$Params, [switch]$RetryOnMissingSession)

    $Session = Ensure-McpSession
    $RequestId = New-McpRequestId -Prefix ($Method -replace '[^a-zA-Z0-9]+', '-')
    $Payload = @{ jsonrpc = '2.0'; id = $RequestId; method = $Method; params = $Params }
    $Body = $Payload | ConvertTo-Json -Depth 100 -Compress
    $Response = Invoke-McpHttp -Method 'POST' -Url $Endpoint -Headers (Get-PostHeaders -SessionId $Session.sessionId) -Body $Body

    if ((($Response.StatusCode -eq 400) -or ($Response.StatusCode -eq 404)) -and $RetryOnMissingSession) {
        Remove-McpSessionFile
        $Session = Ensure-McpSession -ForceRefresh
        $Response = Invoke-McpHttp -Method 'POST' -Url $Endpoint -Headers (Get-PostHeaders -SessionId $Session.sessionId) -Body $Body
    }

    if (($Response.StatusCode -lt 200) -or ($Response.StatusCode -ge 300)) {
        Write-McpFailure -Message ("MCP request failed for method '{0}'." -f $Method) -Response $Response
    }

    $Messages = ConvertFrom-McpResponse -Response $Response
    $JsonRpc = $null
    foreach ($Message in $Messages) {
        if (($null -ne $Message.id) -and ($Message.id.ToString() -eq $RequestId)) {
            $JsonRpc = $Message
            break
        }
    }

    if ($null -eq $JsonRpc) { throw "No JSON-RPC response found for request '$RequestId'." }
    if ($null -ne $JsonRpc.error) {
        throw ('JSON-RPC error for method {0}: {1}' -f $Method, ($JsonRpc.error | ConvertTo-Json -Depth 20 -Compress))
    }

    $JsonRpc.result
}

function Get-ToolArguments {
    if ($ArgumentsJson -and $ArgumentsFile) {
        throw 'Use either -ArgumentsJson or -ArgumentsFile, not both.'
    }

    if ($ArgumentsFile) {
        $Raw = Get-Content -LiteralPath $ArgumentsFile -Raw
        if ([string]::IsNullOrWhiteSpace($Raw)) { return @{} }
        return $Raw | ConvertFrom-Json -Depth 100
    }

    if ($ArgumentsJson) {
        return $ArgumentsJson | ConvertFrom-Json -Depth 100
    }

    @{}
}

switch ($Action) {
    'init' {
        Write-Output (ConvertTo-PrettyJson -Value (Start-McpSession))
    }
    'list-tools' {
        Write-Output (ConvertTo-PrettyJson -Value (Invoke-McpJsonRpc -Method 'tools/list' -Params @{} -RetryOnMissingSession))
    }
    'call-tool' {
        if (-not $ToolName) { throw 'The call-tool action requires -ToolName.' }
        $Result = Invoke-McpJsonRpc -Method 'tools/call' -Params @{ name = $ToolName; arguments = (Get-ToolArguments) } -RetryOnMissingSession
        Write-Output (ConvertTo-PrettyJson -Value $Result)
    }
    'ping' {
        Write-Output (ConvertTo-PrettyJson -Value (Invoke-McpJsonRpc -Method 'ping' -Params @{} -RetryOnMissingSession))
    }
    'show-session' {
        $Session = Load-McpSession
        if ($null -eq $Session) {
            Write-Host "No stored MCP session at $SessionFile"
        }
        else {
            Write-Output (ConvertTo-PrettyJson -Value $Session)
        }
    }
    'close' {
        $Session = Load-McpSession
        if (($null -eq $Session) -or (-not $Session.sessionId)) {
            Write-Host 'No active MCP session file found.'
        }
        else {
            $Response = Invoke-McpHttp -Method 'DELETE' -Url $Endpoint -Headers (Get-DeleteHeaders -SessionId $Session.sessionId) -Body $null
            if (($Response.StatusCode -lt 200) -or ($Response.StatusCode -ge 300)) {
                Write-McpFailure -Message 'Failed to close the MCP session.' -Response $Response
            }
            Remove-McpSessionFile
            Write-Host 'MCP session closed.'
        }
    }
}
