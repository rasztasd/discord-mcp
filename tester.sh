#!/usr/bin/env bash
set -euo pipefail

ACTION="list-tools"
ENDPOINT="http://localhost:8085/mcp"
TOOL_NAME=""
ARGUMENTS_JSON=""
ARGUMENTS_FILE=""
SESSION_FILE="${TMPDIR:-/tmp}/discord-mcp-session.json"
PROTOCOL_VERSION="2025-11-25"
CLIENT_NAME="discord-mcp-agent-tester"
CLIENT_VERSION="0.1.0"
TIMEOUT_SECONDS=60

usage() {
  cat <<'EOF'
Usage:
  mcp-client.sh [options]

Options:
  --action <init|list-tools|call-tool|ping|show-session|close>
  --endpoint <url>
  --tool-name <name>
  --arguments-json <json>
  --arguments-file <path>
  --session-file <path>
  --protocol-version <version>
  --client-name <name>
  --client-version <version>
  --timeout-seconds <n>
  -h, --help

Examples:
  mcp-client.sh --action init
  mcp-client.sh --action list-tools
  mcp-client.sh --action call-tool --tool-name foo --arguments-json '{"x":1}'
  mcp-client.sh --action ping
  mcp-client.sh --action show-session
  mcp-client.sh --action close
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

new_mcp_request_id() {
  local prefix="$1"
  local guid
  if command -v uuidgen >/dev/null 2>&1; then
    guid="$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-')"
  else
    guid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '-')"
  fi
  [[ -n "$guid" ]] || fail "Unable to generate request id"
  printf '%s-%s\n' "$prefix" "$guid"
}

convert_to_pretty_json() {
  jq .
}

remove_mcp_session_file() {
  [[ -f "$SESSION_FILE" ]] && rm -f "$SESSION_FILE"
}

load_mcp_session() {
  [[ -f "$SESSION_FILE" ]] || return 1
  [[ -s "$SESSION_FILE" ]] || return 1
  cat "$SESSION_FILE"
}

save_mcp_session() {
  local session_id="$1"
  local initialize_result_json="$2"

  mkdir -p "$(dirname "$SESSION_FILE")"

  jq -n \
    --arg endpoint "$ENDPOINT" \
    --arg sessionId "$session_id" \
    --arg clientName "$CLIENT_NAME" \
    --arg clientVersion "$CLIENT_VERSION" \
    --arg createdAt "$(date -Iseconds)" \
    --argjson init "$initialize_result_json" \
    '{
      endpoint: $endpoint,
      sessionId: $sessionId,
      protocolVersion: $init.protocolVersion,
      serverInfo: $init.serverInfo,
      clientName: $clientName,
      clientVersion: $clientVersion,
      createdAt: $createdAt
    }' > "$SESSION_FILE"

  cat "$SESSION_FILE"
}

get_post_headers() {
  local session_id="${1:-}"
  local -a headers=(
    -H "Accept: application/json, text/event-stream"
    -H "Content-Type: application/json"
    -H "Cache-Control: no-cache"
    -H "MCP-Protocol-Version: ${PROTOCOL_VERSION}"
  )
  if [[ -n "$session_id" ]]; then
    headers+=(-H "Mcp-Session-Id: ${session_id}")
  fi
  printf '%s\0' "${headers[@]}"
}

get_delete_headers() {
  local session_id="$1"
  local -a headers=(
    -H "Cache-Control: no-cache"
    -H "MCP-Protocol-Version: ${PROTOCOL_VERSION}"
    -H "Mcp-Session-Id: ${session_id}"
  )
  printf '%s\0' "${headers[@]}"
}

write_mcp_failure() {
  local message="$1"
  local body="${2:-}"
  if [[ -z "${body// }" ]]; then
    fail "$message"
  fi
  fail "$(printf '%s\n%s' "$message" "$body")"
}

# Globals set by invoke_mcp_http:
#   HTTP_STATUS
#   HTTP_BODY
#   HTTP_HEADERS_FILE
#   HTTP_BODY_FILE
invoke_mcp_http() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  shift 3
  local -a headers=( "$@" )

  HTTP_HEADERS_FILE="$(mktemp)"
  HTTP_BODY_FILE="$(mktemp)"

  local -a curl_args=(
    -sS
    -X "$method"
    --max-time "$TIMEOUT_SECONDS"
    -D "$HTTP_HEADERS_FILE"
    -o "$HTTP_BODY_FILE"
  )

  if [[ -n "$body" ]]; then
    curl_args+=(--data "$body")
  fi

  curl_args+=("${headers[@]}")
  curl_args+=("$url")

  HTTP_STATUS="$(curl "${curl_args[@]}" -w '%{http_code}')"
  HTTP_BODY="$(cat "$HTTP_BODY_FILE")"
}

get_response_header_value() {
  local name="$1"
  awk -v target="$(echo "$name" | tr '[:upper:]' '[:lower:]')" '
    BEGIN { IGNORECASE=1 }
    {
      sub(/\r$/, "", $0)
      idx = index($0, ":")
      if (idx > 0) {
        key = substr($0, 1, idx - 1)
        val = substr($0, idx + 1)
        sub(/^[[:space:]]+/, "", val)
        if (tolower(key) == target) {
          print val
          exit
        }
      }
    }
  ' "$HTTP_HEADERS_FILE"
}

convert_from_mcp_sse() {
  local text="$1"

  awk '
    function flush_event(    data, first, json) {
      if (data_count == 0 && event_name == "" && event_id == "") return
      data = ""
      for (i = 1; i <= data_count; i++) {
        data = data (i > 1 ? "\n" : "") data_lines[i]
      }
      if (length(data) > 0) {
        print data
      }
      event_name = ""
      event_id = ""
      data_count = 0
      delete data_lines
    }
    {
      sub(/\r$/, "", $0)
      if ($0 == "") {
        flush_event()
        next
      }
      if (substr($0, 1, 1) == ":") next
      idx = index($0, ":")
      if (idx < 1) next
      field = substr($0, 1, idx - 1)
      value = substr($0, idx + 1)
      if (substr(value, 1, 1) == " ") value = substr(value, 2)
      if (field == "event") event_name = value
      else if (field == "id") event_id = value
      else if (field == "data") data_lines[++data_count] = value
    }
    END { flush_event() }
  ' <<< "$text"
}

convert_from_mcp_response() {
  local content_type="$1"
  local body="$2"

  shopt -s nocasematch
  if [[ "$content_type" == *application/json* ]]; then
    [[ -n "${body// }" ]] || return 0
    printf '%s\n' "$body" | jq -c .
    return 0
  fi

  if [[ "$content_type" == *text/event-stream* ]]; then
    [[ -n "${body// }" ]] || return 0
    convert_from_mcp_sse "$body" | while IFS= read -r line; do
      [[ -n "${line// }" ]] || continue
      printf '%s\n' "$line" | jq -c .
    done
    return 0
  fi
  shopt -u nocasematch

  [[ -z "${body// }" ]] && return 0
  fail "Unsupported response content type: $content_type"
}

start_mcp_session() {
  local init_id init_payload
  init_id="$(new_mcp_request_id "initialize")"

  init_payload="$(
    jq -nc \
      --arg id "$init_id" \
      --arg protocolVersion "$PROTOCOL_VERSION" \
      --arg clientName "$CLIENT_NAME" \
      --arg clientVersion "$CLIENT_VERSION" \
      '{
        jsonrpc: "2.0",
        id: $id,
        method: "initialize",
        params: {
          protocolVersion: $protocolVersion,
          capabilities: {},
          clientInfo: { name: $clientName, version: $clientVersion }
        }
      }'
  )"

  local -a headers=()
  while IFS= read -r -d '' h; do headers+=("$h"); done < <(get_post_headers)

  invoke_mcp_http "POST" "$ENDPOINT" "$init_payload" "${headers[@]}"

  if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
    write_mcp_failure "MCP initialize failed." "$HTTP_BODY"
  fi

  local content_type session_id init_message initialize_result ready_payload
  content_type="$(get_response_header_value "Content-Type")"
  mapfile -t _envelopes < <(convert_from_mcp_response "$content_type" "$HTTP_BODY")

  (( ${#_envelopes[@]} == 1 )) || fail "Unexpected initialize response envelope."

  init_message="${_envelopes[0]}"

  if jq -e '.error != null' >/dev/null 2>&1 <<< "$init_message"; then
    fail "Initialize JSON-RPC error: $(jq -c '.error' <<< "$init_message")"
  fi

  session_id="$(get_response_header_value "Mcp-Session-Id")"
  [[ -n "$session_id" ]] || fail "Initialize succeeded but no Mcp-Session-Id header was returned."

  initialize_result="$(jq -c '.result' <<< "$init_message")"

  ready_payload='{"jsonrpc":"2.0","method":"notifications/initialized","params":null}'

  headers=()
  while IFS= read -r -d '' h; do headers+=("$h"); done < <(get_post_headers "$session_id")

  invoke_mcp_http "POST" "$ENDPOINT" "$ready_payload" "${headers[@]}"

  if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
    write_mcp_failure "notifications/initialized failed." "$HTTP_BODY"
  fi

  save_mcp_session "$session_id" "$initialize_result"
}

ensure_mcp_session() {
  local force_refresh="${1:-0}"

  if [[ "$force_refresh" != "1" ]]; then
    if session="$(load_mcp_session 2>/dev/null)"; then
      local existing_endpoint existing_session_id
      existing_endpoint="$(jq -r '.endpoint // empty' <<< "$session")"
      existing_session_id="$(jq -r '.sessionId // empty' <<< "$session")"
      if [[ "$existing_endpoint" == "$ENDPOINT" && -n "$existing_session_id" ]]; then
        printf '%s\n' "$session"
        return 0
      fi
    fi
  fi

  start_mcp_session
}

invoke_mcp_jsonrpc() {
  local method="$1"
  local params_json="$2"
  local retry_on_missing_session="${3:-0}"

  local session request_id payload body session_id content_type jsonrpc
  session="$(ensure_mcp_session 0)"
  session_id="$(jq -r '.sessionId' <<< "$session")"

  request_id="$(new_mcp_request_id "$(sed 's/[^a-zA-Z0-9]\+/-/g' <<< "$method")")"

  payload="$(
    jq -nc \
      --arg id "$request_id" \
      --arg method "$method" \
      --argjson params "$params_json" \
      '{jsonrpc:"2.0", id:$id, method:$method, params:$params}'
  )"

  local -a headers=()
  while IFS= read -r -d '' h; do headers+=("$h"); done < <(get_post_headers "$session_id")

  invoke_mcp_http "POST" "$ENDPOINT" "$payload" "${headers[@]}"

  if (( (HTTP_STATUS == 400 || HTTP_STATUS == 404) && retry_on_missing_session == 1 )); then
    remove_mcp_session_file
    session="$(ensure_mcp_session 1)"
    session_id="$(jq -r '.sessionId' <<< "$session")"

    headers=()
    while IFS= read -r -d '' h; do headers+=("$h"); done < <(get_post_headers "$session_id")

    invoke_mcp_http "POST" "$ENDPOINT" "$payload" "${headers[@]}"
  fi

  if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
    write_mcp_failure "MCP request failed for method '$method'." "$HTTP_BODY"
  fi

  content_type="$(get_response_header_value "Content-Type")"
  jsonrpc="$(
    convert_from_mcp_response "$content_type" "$HTTP_BODY" \
      | jq -c --arg request_id "$request_id" 'select(.id? != null and (.id|tostring) == $request_id)' \
      | head -n 1
  )"

  [[ -n "$jsonrpc" ]] || fail "No JSON-RPC response found for request '$request_id'."

  if jq -e '.error != null' >/dev/null 2>&1 <<< "$jsonrpc"; then
    fail "JSON-RPC error for method $method: $(jq -c '.error' <<< "$jsonrpc")"
  fi

  jq -c '.result' <<< "$jsonrpc"
}

get_tool_arguments() {
  if [[ -n "$ARGUMENTS_JSON" && -n "$ARGUMENTS_FILE" ]]; then
    fail "Use either --arguments-json or --arguments-file, not both."
  fi

  if [[ -n "$ARGUMENTS_FILE" ]]; then
    [[ -f "$ARGUMENTS_FILE" ]] || fail "Arguments file not found: $ARGUMENTS_FILE"
    [[ -s "$ARGUMENTS_FILE" ]] || { echo '{}'; return 0; }
    jq -c . < "$ARGUMENTS_FILE"
    return 0
  fi

  if [[ -n "$ARGUMENTS_JSON" ]]; then
    jq -c . <<< "$ARGUMENTS_JSON"
    return 0
  fi

  echo '{}'
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --action) ACTION="${2:?}"; shift 2 ;;
      --endpoint) ENDPOINT="${2:?}"; shift 2 ;;
      --tool-name) TOOL_NAME="${2:?}"; shift 2 ;;
      --arguments-json) ARGUMENTS_JSON="${2:?}"; shift 2 ;;
      --arguments-file) ARGUMENTS_FILE="${2:?}"; shift 2 ;;
      --session-file) SESSION_FILE="${2:?}"; shift 2 ;;
      --protocol-version) PROTOCOL_VERSION="${2:?}"; shift 2 ;;
      --client-name) CLIENT_NAME="${2:?}"; shift 2 ;;
      --client-version) CLIENT_VERSION="${2:?}"; shift 2 ;;
      --timeout-seconds) TIMEOUT_SECONDS="${2:?}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) fail "Unknown argument: $1" ;;
    esac
  done

  case "$ACTION" in
    init|list-tools|call-tool|ping|show-session|close) ;;
    *) fail "Invalid --action: $ACTION" ;;
  esac
}

main() {
  require_cmd curl
  require_cmd jq

  parse_args "$@"

  case "$ACTION" in
    init)
      start_mcp_session | convert_to_pretty_json
      ;;
    list-tools)
      invoke_mcp_jsonrpc "tools/list" '{}' 1 | convert_to_pretty_json
      ;;
    call-tool)
      [[ -n "$TOOL_NAME" ]] || fail "The call-tool action requires --tool-name."
      local args_json result
      args_json="$(get_tool_arguments)"
      result="$(
        jq -nc \
          --arg name "$TOOL_NAME" \
          --argjson arguments "$args_json" \
          '{name:$name, arguments:$arguments}'
      )"
      invoke_mcp_jsonrpc "tools/call" "$result" 1 | convert_to_pretty_json
      ;;
    ping)
      invoke_mcp_jsonrpc "ping" '{}' 1 | convert_to_pretty_json
      ;;
    show-session)
      if session="$(load_mcp_session 2>/dev/null)"; then
        printf '%s\n' "$session" | convert_to_pretty_json
      else
        echo "No stored MCP session at $SESSION_FILE"
      fi
      ;;
    close)
      if ! session="$(load_mcp_session 2>/dev/null)"; then
        echo "No active MCP session file found."
        exit 0
      fi

      local session_id
      session_id="$(jq -r '.sessionId // empty' <<< "$session")"
      if [[ -z "$session_id" ]]; then
        echo "No active MCP session file found."
        exit 0
      fi

      local -a headers=()
      while IFS= read -r -d '' h; do headers+=("$h"); done < <(get_delete_headers "$session_id")

      invoke_mcp_http "DELETE" "$ENDPOINT" "" "${headers[@]}"

      if (( HTTP_STATUS < 200 || HTTP_STATUS >= 300 )); then
        write_mcp_failure "Failed to close the MCP session." "$HTTP_BODY"
      fi

      remove_mcp_session_file
      echo "MCP session closed."
      ;;
  esac
}

main "$@"
