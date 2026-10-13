using System.Globalization;
using System.Net;
using System.Text.RegularExpressions;

namespace KerterCore.Strikeout;

/// Lectura del HTML público de strikeout.im: calendario por deporte y streams de cada partido.
public static partial class StrikeoutSite
{
    public static readonly Uri Base = new("https://strikeout.im");
    /// El mismo User-Agent en todas las peticiones: los tokens de la página van ligados al cliente.
    public const string UserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15";

    public sealed record Sport(string Slug, string Name);

    public static readonly Sport[] Sports =
    [
        new("soccer", "Fútbol"), new("basketball", "Baloncesto"), new("football", "NFL"), new("baseball", "Béisbol"),
        new("hockey", "Hockey"), new("tennis", "Tenis"), new("formula-1", "Fórmula 1"), new("motogp", "MotoGP"),
        new("ufc", "UFC"), new("boxing", "Boxeo"), new("rugby", "Rugby"), new("golf", "Golf"), new("nascar", "NASCAR"),
        new("cycling", "Ciclismo"), new("wwe", "WWE"), new("fighting", "Lucha"), new("darts", "Dardos"),
        new("afl", "AFL"), new("racing", "Carreras"),
    ];

    public sealed record Event(string Path, string Title, string Flag, DateTimeOffset? Start)
    {
        public Uri Url => new(Base, Path);
    }

    public sealed record Stream(string Path, string Name, string? Language, bool IsHD)
    {
        public Uri Url => new(Base, Path);
        /// "Stream 3 · Español · HD", para el selector del reproductor.
        public string Label => string.Join(" · ", new[] { Name, Language, IsHD ? "HD" : null }.Where(s => s != null));
    }

    internal static readonly HttpClient Http = new(new SocketsHttpHandler
    {
        AutomaticDecompression = DecompressionMethods.All,
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
    }) { Timeout = TimeSpan.FromSeconds(20) };

    // MARK: Calendario

    public static async Task<List<Event>> ScheduleAsync(Sport sport, CancellationToken ct = default)
    {
        var html = await PageAsync(new Uri(Base, sport.Slug), ct);
        // Las horas vienen en la zona del sitio (siteConfig.tzOffSet, en horas respecto a UTC).
        var offset = FirstMatch("\"tzOffSet\":(-?\\d+)", html) is { } o ? int.Parse(o[0]) : 0;
        const string pattern = "<a class=\"mb-1 btn btn-primary[^\"]*\"[^>]*href=\"([^\"]+)\" title=\"([^\"]*)\"><span class=\"align-bottom me-2 strikeout ([^\" ]*)[^\"]*\"></span>\\s*(?:<span content=\"([^\"]+)\")?";
        return Matches(pattern, html).Select(g =>
        {
            DateTimeOffset? start = null;
            if (g[3].Length > 0 && DateTime.TryParseExact(g[3], "yyyy-MM-dd'T'HH:mm", CultureInfo.InvariantCulture,
                    DateTimeStyles.None, out var local))
                start = new DateTimeOffset(local, TimeSpan.FromHours(offset));
            return new Event(g[0], DecodeEntities(g[1]), g[2], start);
        }).ToList();
    }

    // MARK: Streams de un partido

    public static async Task<List<Stream>> StreamsAsync(Event ev, CancellationToken ct = default)
    {
        var html = await PageAsync(ev.Url, ct);
        List<Stream> Single() => [new Stream(ev.Path, "Stream 1", null, false)];
        // El bloque de escritorio ("More Video Links") trae cada stream una vez.
        if (FirstMatch("More Video Links (.*?)</div>", html) is not { } block) return Single();
        var streams = Matches("data-uri=\"([^\"]+)\"[^>]*>([^<]+)(.*?)</a>", block[0]).Select(g =>
            new Stream(g[0], g[1].Trim(), FirstMatch("text-muted[^>]*>([^<]+)<", g[2])?[0], g[2].Contains(">HD<"))).ToList();
        return streams.Count == 0 ? Single() : streams;
    }

    // MARK: Utilidades

    public static async Task<string> PageAsync(Uri url, CancellationToken ct = default) =>
        await FetchAsync(url, new Dictionary<string, string>(), ct);

    internal static async Task<string> FetchAsync(Uri url, IReadOnlyDictionary<string, string> headers, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        req.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
        foreach (var (k, v) in headers) req.Headers.TryAddWithoutValidation(k, v);
        using var resp = await Http.SendAsync(req, ct);
        if (!resp.IsSuccessStatusCode) throw new HttpRequestException($"HTTP {(int)resp.StatusCode}", null, resp.StatusCode);
        return await resp.Content.ReadAsStringAsync(ct);
    }

    private static string DecodeEntities(string t) =>
        t.Replace("&amp;", "&").Replace("&#039;", "'").Replace("&#39;", "'").Replace("&quot;", "\"");

    internal static string[]? FirstMatch(string pattern, string text) => Matches(pattern, text).FirstOrDefault();

    /// Todas las coincidencias, cada una como sus grupos capturados ("" si un grupo opcional no casó).
    internal static IEnumerable<string[]> Matches(string pattern, string text) =>
        Regex.Matches(text, pattern, RegexOptions.Singleline)
            .Select(m => m.Groups.Cast<Group>().Skip(1).Select(g => g.Success ? g.Value : "").ToArray());
}
