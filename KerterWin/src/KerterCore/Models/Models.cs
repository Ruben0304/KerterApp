using System.Text.Json;
using KerterCore.Util;

namespace KerterCore.Models;

public sealed record User(string Id, string? Name, string? Email)
{
    public static User? From(JsonElement e)
    {
        if (e.ValueKind != JsonValueKind.Object) return null;
        return new User(e.FirstString("id", "_id", "userId", "uuid") ?? Guid.NewGuid().ToString(),
            e.FirstString("name", "fullName", "username", "displayName"), e.FirstString("email", "mail"));
    }
}

/// Canal reproducible (Kerter o Strikeout).
public sealed class Channel
{
    public const string StrikeoutPlayerType = "strikeout";

    public required string Id { get; init; }
    public string Name { get; set; } = "Canal";
    public string? Category { get; set; }
    public Uri? LogoUrl { get; set; }
    public Uri? StreamUrl { get; set; }
    public string? PlayerType { get; set; }
    public string? DrmKeyId { get; set; }
    public string? DrmKey { get; set; }
    public bool IsLive { get; set; }

    public bool HasDrm => !string.IsNullOrEmpty(DrmKey);
    public bool IsStrikeout => PlayerType == StrikeoutPlayerType;
    public bool IsDash => string.Equals(PlayerType, "dash", StringComparison.OrdinalIgnoreCase);

    public static Channel FromJson(JsonElement c, Uri mediaBase)
    {
        Uri? Url(params string[] keys)
        {
            var s = c.FirstString(keys);
            if (s == null) return null;
            if (s.StartsWith("http")) return Uri.TryCreate(s, UriKind.Absolute, out var u) ? u : null;
            return Uri.TryCreate(mediaBase.AbsoluteUri.TrimEnd('/') + (s.StartsWith('/') ? s : "/" + s), UriKind.Absolute, out var r) ? r : null;
        }

        string? category = c.FirstString("category", "categoryName", "group", "genre", "type")
            ?? c.FirstString("tags")?.Split(',').FirstOrDefault()?.Trim();

        string? Nested(params string[] keys)
        {
            foreach (var parent in new[] { "drm", "drmInfo", "clearKey", "clearkey", "license" })
                if (c.Obj(parent) is { } o && o.FirstString(keys) is { } v) return v;
            return null;
        }

        var kid = c.FirstString("drm_key1_id", "drmKey1Id", "drmKeyId", "drm_key_id", "drmKid", "kid", "KID",
                "clearkey_kid", "clearkeyKid", "keyId", "key_id")
            ?? DrmKeys.CanonicalHex(Nested("kid", "KID", "keyId", "key_id"));
        var key = c.FirstString("drm_key1", "drmKey1", "drmKey", "drm_key", "key", "KEY", "clearkey_key",
                "clearkeyKey", "contentKey")
            ?? DrmKeys.CanonicalHex(Nested("key", "KEY", "contentKey"));

        var stream = Url("stream_url", "streamUrl", "sourceUrl", "url", "hls", "hlsUrl", "manifest", "manifestUrl",
            "playbackUrl", "src", "link");

        bool live;
        if (c.FirstBool("isLive", "live", "online") is { } b) live = b;
        else if (c.FirstString("status", "state") is { } st)
        {
            var l = st.ToLowerInvariant();
            live = l.Contains("live") || l.Contains("vivo") || l is "online" or "on";
        }
        else live = stream != null;

        return new Channel
        {
            Id = c.FirstString("id", "_id", "channelId", "uuid", "slug") ?? Guid.NewGuid().ToString(),
            Name = c.FirstString("name", "title", "channelName", "label") ?? "Canal",
            Category = category,
            LogoUrl = Url("logo", "logoUrl", "icon", "iconUrl", "image", "thumbnail", "thumb"),
            StreamUrl = stream,
            PlayerType = c.FirstString("player_type", "playerType"),
            DrmKeyId = kid is null ? null : DrmKeys.CanonicalHex(kid) ?? kid,
            DrmKey = key is null ? null : DrmKeys.CanonicalHex(key) ?? key,
            IsLive = live,
        };
    }
}

/// Fila cruda de `/api/assignments`: una asignación evento → canal.
public sealed record Assignment(string? EventApiId, string? EventTitle, string? EventLeague, string? EventSport,
    string? EventTime, string? EventDate, int? ChannelId, string? ChannelName, string? ChannelLogo,
    string? HomeLogo, string? AwayLogo, bool Hidden)
{
    public static Assignment From(JsonElement e) => new(
        e.FirstString("event_api_id", "eventApiId"), e.FirstString("event_title", "eventTitle"),
        e.FirstString("event_league", "eventLeague"), e.FirstString("event_sport", "eventSport"),
        e.FirstString("event_time", "eventTime"), e.FirstString("event_date", "eventDate"),
        int.TryParse(e.FirstString("channel_id", "channelId"), out var id) ? id : null,
        e.FirstString("channel_name", "channelName"), e.FirstString("channel_logo", "channelLogo"),
        e.FirstString("home_logo", "homeLogo"), e.FirstString("away_logo", "awayLogo"),
        e.FirstBool("hidden") ?? false);
}

/// Un canal que transmite un evento.
public sealed record EventChannel(int Id, string Name, Uri? Logo)
{
    private string NameKey => Text.Key(Name).Replace(" ", "");

    /// "Kerter+ 1", "Kerter Plus 4K"…: los propios, que suelen ir mejor que los de terceros.
    public bool IsKerterPlus => NameKey.Contains("kerter");

    /// Calidad que anuncia el nombre: 4K/UHD > FHD/1080 > HD > sin indicar.
    public int QualityRank
    {
        get
        {
            var k = NameKey;
            if (k.Contains("4k") || k.Contains("uhd") || k.Contains("2160")) return 3;
            if (k.Contains("fhd") || k.Contains("1080")) return 2;
            if (k.Contains("hd") || k.Contains("720")) return 1;
            return 0;
        }
    }
}

public sealed record LiveEvent(string Id, string Home, string Away, string? League, string? Sport, string? Time,
    Uri? HomeLogo, Uri? AwayLogo, List<EventChannel> Channels)
{
    /// "Elche vs Real Madrid" (local vs visitante).
    public string Title => Home.Length == 0 ? Away : $"{Home} vs {Away}";

    /// La hora de la cartelera ("20:45", "8:45 p. m.") como fecha de hoy.
    public DateTime? ScheduledStart
    {
        get
        {
            var m = System.Text.RegularExpressions.Regex.Match(Time ?? "", @"(\d{1,2})[:.](\d{2})");
            if (!m.Success) return null;
            var hour = int.Parse(m.Groups[1].Value);
            var minute = int.Parse(m.Groups[2].Value);
            if (hour >= 24 || minute >= 60) return null;
            var lower = (Time ?? "").ToLowerInvariant().Replace(" ", "").Replace(".", "");
            if (lower.Contains("pm") && hour < 12) hour += 12;
            if (lower.Contains("am") && hour == 12) hour = 0;
            return DateTime.Today.AddHours(hour).AddMinutes(minute);
        }
    }

    private static Uri? U(string? s) => string.IsNullOrEmpty(s) ? null : Uri.TryCreate(s, UriKind.Absolute, out var u) ? u : null;

    /// Agrupa las asignaciones por evento y junta sus canales.
    public static List<LiveEvent> Group(IEnumerable<Assignment> assignments)
    {
        var order = new List<string>();
        var map = new Dictionary<string, LiveEvent>();
        foreach (var a in assignments.Where(a => !a.Hidden))
        {
            var raw = a.EventTitle ?? "Evento";
            var key = a.EventApiId ?? raw;
            // El backend usa el formato "Visitante at Local".
            var parts = raw.Split(" at ");
            var away = parts.Length == 2 ? parts[0].Trim() : raw;
            var home = parts.Length == 2 ? parts[1].Trim() : "";
            if (!map.ContainsKey(key))
            {
                order.Add(key);
                map[key] = new LiveEvent(key, home, away, a.EventLeague,
                    SportsFilter.CanonicalSport(a.EventSport, a.EventLeague), a.EventTime,
                    U(a.HomeLogo), U(a.AwayLogo), []);
            }
            if (a.ChannelId is { } cid && !string.IsNullOrEmpty(a.ChannelName)
                && map[key].Channels.All(c => c.Id != cid))
                map[key].Channels.Add(new EventChannel(cid, a.ChannelName, U(a.ChannelLogo)));
        }
        return order.Select(k => map[k]).Where(e => e.Channels.Count > 0).ToList();
    }

    /// Local y visitante; si el backend no usa "Visitante at Local", se parte por "vs" o guion.
    public (string Home, string Away)? Teams()
    {
        if (Home.Length > 0) return (Home, Away);
        foreach (var sep in new[] { " vs. ", " vs ", " VS ", " v ", " - ", " – " })
        {
            var p = Away.Split(sep);
            if (p.Length == 2) return (p[0].Trim(), p[1].Trim());
        }
        return null;
    }
}

public static class SportsFilter
{
    public static readonly string[] AllSports =
        ["Fútbol", "Tenis", "Baloncesto", "Deporte motor", "Motociclismo", "Boxeo", "UFC", "Béisbol", "Otros"];

    /// Lleva el deporte que manda el backend a uno de `AllSports`.
    public static string? CanonicalSport(string? sport, string? league)
    {
        if (league != null && AllSports.FirstOrDefault(s => s != "Otros" && Text.Fold(s).Trim() == Text.Fold(league).Trim()) is { } named)
            return named;
        if (string.IsNullOrEmpty(sport)) return null;
        var s = Text.Fold(sport).Trim();
        if (s.Contains("americano") || s.Contains("american") || s.Contains("nfl")) return "Otros";
        (string, string)[] table =
        [
            ("soccer", "Fútbol"), ("futbol", "Fútbol"), ("football", "Fútbol"),
            ("tennis", "Tenis"), ("tenis", "Tenis"), ("basket", "Baloncesto"), ("baloncesto", "Baloncesto"),
            ("baseball", "Béisbol"), ("beisbol", "Béisbol"), ("boxing", "Boxeo"), ("boxeo", "Boxeo"),
            ("mma", "UFC"), ("ufc", "UFC"),
            ("motorcycl", "Motociclismo"), ("motociclismo", "Motociclismo"), ("motogp", "Motociclismo"),
            ("motor", "Deporte motor"), ("racing", "Deporte motor"), ("formula", "Deporte motor"),
        ];
        return table.FirstOrDefault(t => s.Contains(t.Item1)).Item2 ?? "Otros";
    }
}
