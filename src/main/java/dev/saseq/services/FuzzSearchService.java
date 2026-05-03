package dev.saseq.services;

import net.dv8tion.jda.api.JDA;
import net.dv8tion.jda.api.entities.Guild;
import net.dv8tion.jda.api.entities.Member;
import net.dv8tion.jda.api.entities.Role;
import net.dv8tion.jda.api.entities.channel.middleman.GuildChannel;
import org.springframework.ai.tool.annotation.Tool;
import org.springframework.ai.tool.annotation.ToolParam;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import java.util.Comparator;
import java.util.List;
import java.util.stream.Collectors;

@Service
public class FuzzSearchService {

    private final JDA jda;

    @Value("${DISCORD_GUILD_ID:}")
    private String defaultGuildId;

    public FuzzSearchService(JDA jda) {
        this.jda = jda;
    }

    private Guild getGuild(String guildId) {
        if ((guildId == null || guildId.isEmpty()) && defaultGuildId != null && !defaultGuildId.isEmpty()) {
            guildId = defaultGuildId;
        }
        if (guildId == null || guildId.isEmpty()) throw new IllegalArgumentException("guildId cannot be null");
        Guild guild = jda.getGuildById(guildId);
        if (guild == null) throw new IllegalArgumentException("Discord server not found by guildId");
        return guild;
    }

    private List<Member> getCachedMembers(Guild guild) {
        if (!guild.isLoaded()) {
            throw new IllegalStateException("Guild members are still loading. Try again once the member cache has finished initializing.");
        }
        return guild.getMembers();
    }

    // Rolling-array Levenshtein distance
    private int levenshtein(String a, String b) {
        int m = a.length(), n = b.length();
        int[] prev = new int[n + 1];
        int[] curr = new int[n + 1];
        for (int j = 0; j <= n; j++) prev[j] = j;
        for (int i = 1; i <= m; i++) {
            curr[0] = i;
            for (int j = 1; j <= n; j++) {
                if (a.charAt(i - 1) == b.charAt(j - 1)) {
                    curr[j] = prev[j - 1];
                } else {
                    curr[j] = 1 + Math.min(prev[j - 1], Math.min(prev[j], curr[j - 1]));
                }
            }
            int[] tmp = prev;
            prev = curr;
            curr = tmp;
        }
        return prev[n];
    }

    // Normalized Levenshtein ratio (0-100)
    private int levenshteinRatio(String a, String b) {
        int maxLen = Math.max(a.length(), b.length());
        if (maxLen == 0) return 100;
        return (int) Math.round((1.0 - (double) levenshtein(a, b) / maxLen) * 100);
    }

    // Partial ratio: slide the shorter string over the longer and take best window match
    private int partialRatio(String query, String target) {
        if (query.length() > target.length()) return levenshteinRatio(query, target);
        int best = 0;
        for (int i = 0; i <= target.length() - query.length(); i++) {
            int score = levenshteinRatio(query, target.substring(i, i + query.length()));
            if (score > best) best = score;
        }
        return best;
    }

    // Final fuzz score = max(full ratio, partial ratio)
    private int fuzzScore(String query, String target) {
        if (query == null || target == null || query.isEmpty() || target.isEmpty()) return 0;
        String q = query.toLowerCase().trim();
        String t = target.toLowerCase().trim();
        return Math.max(levenshteinRatio(q, t), partialRatio(q, t));
    }

    // Best score across multiple nullable candidate fields
    private int bestScore(String query, String... fields) {
        int best = 0;
        for (String field : fields) {
            if (field != null && !field.isEmpty()) {
                int s = fuzzScore(query, field);
                if (s > best) best = s;
            }
        }
        return best;
    }

    @Tool(name = "fuzz_search_members", description = "Fuzzy search for server members across server nickname, account username and display name. Returns all members sorted by match confidence.")
    public String fuzzSearchMembers(
            @ToolParam(description = "Search query") String query,
            @ToolParam(description = "Discord server ID", required = false) String guildId) {
        if (query == null || query.isEmpty()) throw new IllegalArgumentException("query cannot be null");
        Guild guild = getGuild(guildId);

        record Result(Member member, int score) {}

        List<Member> allMembers = getCachedMembers(guild);

        List<Result> results = allMembers.stream()
                .map(m -> new Result(m, bestScore(query,
                        m.getNickname(),
                        m.getUser().getName(),
                        m.getUser().getGlobalName())))
                .sorted(Comparator.comparingInt(Result::score).reversed())
                .toList();

        if (results.isEmpty()) return "No members found.";

        return "Fuzz search results for \"" + query + "\" (" + results.size() + " members):\n" +
                results.stream().limit(5)
                        .map(r -> {
                            String nick = r.member().getNickname();
                            String globalName = r.member().getUser().getGlobalName();
                            return String.format("- %s%s%s (ID: %s) | confidence: %d%%",
                                    r.member().getUser().getName(),
                                    nick != null ? ", nick: " + nick : "",
                                    globalName != null ? ", display: " + globalName : "",
                                    r.member().getId(),
                                    r.score());
                        })
                        .collect(Collectors.joining("\n"));
    }

    @Tool(name = "fuzz_search_roles", description = "Fuzzy search for server roles by name. Returns all roles sorted by match confidence.")
    public String fuzzSearchRoles(
            @ToolParam(description = "Search query") String query,
            @ToolParam(description = "Discord server ID", required = false) String guildId) {
        if (query == null || query.isEmpty()) throw new IllegalArgumentException("query cannot be null");
        Guild guild = getGuild(guildId);

        record Result(Role role, int score) {}

        List<Result> results = guild.getRoles().stream()
                .map(r -> new Result(r, fuzzScore(query, r.getName())))
                .sorted(Comparator.comparingInt(Result::score).reversed())
                .toList();

        if (results.isEmpty()) return "No roles found.";

        return "Fuzz search results for \"" + query + "\" (" + results.size() + " roles):\n" +
                results.stream()
                        .map(r -> String.format("- %s (ID: %s) | confidence: %d%%",
                                r.role().getName(),
                                r.role().getId(),
                                r.score()))
                        .collect(Collectors.joining("\n"));
    }

    @Tool(name = "fuzz_search_channels", description = "Fuzzy search for server channels by name. Returns all channels sorted by match confidence.")
    public String fuzzSearchChannels(
            @ToolParam(description = "Search query") String query,
            @ToolParam(description = "Discord server ID", required = false) String guildId) {
        if (query == null || query.isEmpty()) throw new IllegalArgumentException("query cannot be null");
        Guild guild = getGuild(guildId);

        record Result(GuildChannel channel, int score) {}

        List<Result> results = guild.getChannels().stream()
                .map(c -> new Result(c, fuzzScore(query, c.getName())))
                .sorted(Comparator.comparingInt(Result::score).reversed())
                .toList();

        if (results.isEmpty()) return "No channels found.";

        return "Fuzz search results for \"" + query + "\" (" + results.size() + " channels):\n" +
                results.stream()
                        .map(r -> String.format("- %s (ID: %s, type: %s) | confidence: %d%%",
                                r.channel().getName(),
                                r.channel().getId(),
                                r.channel().getType().name(),
                                r.score()))
                        .collect(Collectors.joining("\n"));
    }
}
