using System.Text;
using System.Text.Json;
using KerterCore.Util;
using static KerterCore.Strikeout.StrikeoutSite;

namespace KerterCore.Strikeout;

public enum NativeError { Missing, AuthRejected, NotStarted, Offline }

public class NativeException(string message, NativeError kind, DateTimeOffset? startsAt = null) : Exception(message)
{
    public NativeError Reason { get; } = kind;
    public DateTimeOffset? StartsAt { get; } = startsAt;
}

/// Saca el HLS del reproductor del embed, sin su página.
///
/// Cadena: página del stream → iframe `/sd0embed` (con los tokens de `siteConfig`) → autenticación
/// en el servidor de claves → `manifest.ts?u_id=…`, que redirige al master `play.m3u8`.
/// El CDN y la clave AES solo exigen `Referer`/`Origin` del dominio del embed; la sesión se
/// renueva cada 5 minutos como hace el reproductor web.
public sealed class NativeStream
{
    public required Uri MasterUrl { get; init; }
    /// Cabeceras que hay que mandar en playlists, segmentos y clave.
    public required IReadOnlyDictionary<string, string> Headers { get; init; }
    internal AuthSession Session { get; init; } = null!;

    internal sealed class AuthSession
    {
        public required Uri AuthBase;
        public required string Stream, HostId, TokenHeader, Origin;
        public required string SCode, SessionId, DeviceId;
        public required long Expires;

        public Uri Url(bool refresh)
        {
            var items = new List<(string, string)>
            {
                ("scode", SCode), ("stream", Stream), ("expires", Expires.ToString()), ("u_id", DeviceId),
                ("session_id", SessionId), ("host_id", HostId),
            };
            if (refresh) items.Add(("r", "1"));
            var b = new UriBuilder(AuthBase) { Query = Text.FormEncode(items) };
            return b.Uri;
        }
    }

    public static async Task<NativeStream> ResolveAsync(Uri streamPage, CancellationToken ct = default)
    {
        // 1. Página del stream: tokens para pedir el iframe.
        var page = await PageAsync(streamPage, ct);
        if (FirstMatch(@"const siteConfig = (\{.*?\});", page)?[0] is not { } configJson)
            throw new NativeException("No se encontró siteConfig.", NativeError.Missing);
        using var configDoc = JsonDocument.Parse(configJson);
        var config = configDoc.RootElement;

        string Value(string pattern)
        {
            if (FirstMatch(pattern, page)?[0] is { } found) return found;
            if (config.TryGetProperty("event_start_ts", out var ts) && ts.ValueKind == JsonValueKind.Number
                && ts.GetDouble() > DateTimeOffset.UtcNow.ToUnixTimeSeconds())
                throw new NativeException("El partido aún no ha empezado.", NativeError.NotStarted,
                    DateTimeOffset.FromUnixTimeSeconds((long)ts.GetDouble()));
            throw new NativeException($"Falta {pattern}", NativeError.Missing);
        }
        string Cfg(string key) => config.FirstString(key) ?? throw new NativeException($"Falta {key}", NativeError.Missing);

        var gameText = Value("gameText\\s*=\\s*\"([^\"]*)\"");
        var gameCat = Value("gameCat\\s*=\\s*\"([^\"]*)\"");
        var zmid = Value("zmid\\s*=\\s*\"([^\"]*)\"");
        var pid = Value("pid\\s*=\\s*(\\d+)");
        var embedDomain = Value("edm\\s*=\\s*\"([^\"]*)\"");

        // 2. Iframe del reproductor (mismos parámetros que arma embed-V2.min.js).
        var embed = new UriBuilder("https", embedDomain) { Path = $"/sd0embed/{gameCat}" };
        embed.Query = Text.FormEncode(
        [
            ("pid", pid), ("gacat", gameText), ("gatxt", gameCat), ("v", zmid), ("csrf", Cfg("csrf")),
            ("csrf_ip", Cfg("csrf_ip")), ("expires", Cfg("sec_expires")), ("sec_hash", Cfg("sec_hash")),
        ]);
        var origin = $"https://{embedDomain}";
        var player = await FetchAsync(embed.Uri, new Dictionary<string, string> { ["Referer"] = Base.AbsoluteUri }, ct);

        // 3. Datos del script del reproductor (minificado: se localiza por cómo se usa, no por nombre).
        var script = Matches(@"<script[^>]*>(.*?)</script>", player).Select(m => m[0])
            .FirstOrDefault(s => s.Contains("session_id") && s.Contains("atob"));
        if (script == null)
            throw player.Contains("Stream is Offline")
                ? new NativeException("Stream is Offline", NativeError.Offline)
                : new NativeException("Falta el script del reproductor.", NativeError.Missing);

        static string CharCodes(string list) =>
            Encoding.UTF8.GetString(list.Split(',').Select(s => byte.TryParse(s, out var b) ? (byte?)b : null)
                .Where(b => b != null).Select(b => b!.Value).ToArray());
        string? Literal(string name) =>
            FirstMatch($"[,;]{System.Text.RegularExpressions.Regex.Escape(name)}=(?:\\(parseInt\\(\"\\d+\",10\\),)?\"([^\"]*)\"", script)?[0];
        string? VariableUsedAs(string usage) =>
            FirstMatch(usage, script)?[0] is { } name ? Literal(name) : null;
        static string? B64(string? t)
        {
            if (t == null) return null;
            try { return Encoding.UTF8.GetString(Convert.FromBase64String(t)); } catch (FormatException) { return null; }
        }

        var encoded = Matches("[\\w$]+\\(\"([A-Za-z0-9+/=]{16,})\"\\)", script).Select(m => m[0]).ToList();
        var authBase = encoded.Select(B64).Where(s => s != null && s.StartsWith("http")).Select(s => new Uri(s!)).FirstOrDefault();
        var tokenHeader = encoded.Select(e => B64(B64(e))).FirstOrDefault(s => s != null && !s.StartsWith("http"));
        // `D(W([...]))` es la fuente (dos capas base64); el `W([...])` suelto es el scode.
        var sourceCodes = FirstMatch(@"[\w$]+\([\w$]+\(\[([\d,]+)\]\)\)", script)?[0];
        Uri? source = null;
        if (sourceCodes != null && B64(B64(CharCodes(sourceCodes))) is { } s2) Uri.TryCreate(s2, UriKind.Absolute, out source);
        var scode = FirstMatch(@"(?<!\()[\w$]+\(\[([\d,]+)\]\)", script)?[0] is { } sc ? CharCodes(sc) : null;
        var ids = FirstMatch("session_id:\"([^\"]+)\",device_id:([\\w$]+)", script);
        var deviceId = ids != null ? Literal(ids[1]) : null;
        long? expires = FirstMatch("parseInt\\(\"(\\d{9,})\",10\\)", script)?[0] is { } ex ? long.Parse(ex) : null;
        var streamId = VariableUsedAs(@"stream=\$\{encodeURIComponent\(([\w$]+)\)\}");
        var hostId = VariableUsedAs("host_id=`\\+encodeURIComponent\\(([\\w$]+)\\)");
        if (authBase == null || tokenHeader == null || source == null || scode == null || ids == null || deviceId == null
            || expires == null || streamId == null || hostId == null)
            throw new NativeException("Falta la fuente o la autenticación.", NativeError.Missing);

        // 4. Autenticación inicial: devuelve el device_id con el que se firma el manifest.
        var session = new AuthSession
        {
            AuthBase = authBase, Stream = streamId, HostId = hostId, TokenHeader = tokenHeader, Origin = origin,
            SCode = scode, Expires = expires.Value, SessionId = ids[0], DeviceId = deviceId,
        };
        await AuthenticateAsync(session, false, ct);

        var q = System.Web.HttpUtility.ParseQueryString(source.Query);
        var pairs = q.AllKeys.Where(k => k != null && k != "u_id").Select(k => (k!, q[k]!)).ToList();
        pairs.Add(("u_id", session.DeviceId));
        var media = new UriBuilder(source) { Query = Text.FormEncode(pairs) };
        return new NativeStream
        {
            MasterUrl = media.Uri,
            Headers = new Dictionary<string, string>
            {
                ["Referer"] = origin + "/", ["Origin"] = origin, ["User-Agent"] = UserAgent,
            },
            Session = session,
        };
    }

    /// Renueva la sesión; el reproductor web lo hace cada 5 minutos y corta si falla.
    public Task RefreshAsync(CancellationToken ct = default) => AuthenticateAsync(Session, true, ct);

    private static async Task AuthenticateAsync(AuthSession s, bool refresh, CancellationToken ct)
    {
        var body = await FetchAsync(s.Url(refresh), new Dictionary<string, string>
        {
            ["Accept"] = "application/json", ["X-CSRF-Auth"] = s.TokenHeader, ["Origin"] = s.Origin, ["Referer"] = s.Origin + "/",
        }, ct);
        try
        {
            using var d = JsonDocument.Parse(body);
            var r = d.RootElement;
            if (r.TryGetProperty("success", out var ok) && ok.ValueKind == JsonValueKind.False) throw new NativeException("", NativeError.AuthRejected);
            s.SCode = r.GetProperty("scode").GetString()!;
            s.Expires = r.GetProperty("ts").GetInt64();
            s.SessionId = r.GetProperty("session_id").GetString()!;
            s.DeviceId = r.GetProperty("device_id").GetString()!;
        }
        catch (Exception e) when (e is JsonException or KeyNotFoundException or InvalidOperationException)
        {
            throw new NativeException("El servidor de Strikeout rechazó la sesión.", NativeError.AuthRejected);
        }
    }
}
