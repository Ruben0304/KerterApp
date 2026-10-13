using System.Net;
using System.Net.Sockets;
using System.Text;

namespace KerterCore.Playback;

/// Proxy local que añade cabeceras (Referer/Origin/User-Agent) a todo lo que pide el reproductor:
/// playlists, segmentos y claves AES. LibVLC solo sabe mandar Referer y User-Agent, y el CDN de
/// Strikeout exige también `Origin`. Las playlists se reescriben para que todo pase por aquí.
public sealed class HeaderProxy : IDisposable
{
    private readonly HttpListener _listener = new();
    private readonly HttpClient _http;
    private readonly IReadOnlyDictionary<string, string> _headers;
    private readonly CancellationTokenSource _cts = new();
    private readonly int _port;

    public HeaderProxy(IReadOnlyDictionary<string, string> headers)
    {
        _headers = headers;
        _http = new HttpClient(new SocketsHttpHandler
        {
            AutomaticDecompression = DecompressionMethods.All,
            MaxConnectionsPerServer = 16,
        }) { Timeout = TimeSpan.FromSeconds(30) };
        var probe = new TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        _port = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        _listener.Prefixes.Add($"http://127.0.0.1:{_port}/");
        _listener.Start();
        _ = Task.Run(AcceptLoop);
    }

    /// URL local equivalente a la remota.
    public Uri Wrap(Uri upstream) => new($"http://127.0.0.1:{_port}/p/{Encode(upstream.AbsoluteUri)}");

    private static string Encode(string s) =>
        Convert.ToBase64String(Encoding.UTF8.GetBytes(s)).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static string Decode(string s)
    {
        s = s.Replace('-', '+').Replace('_', '/');
        s += new string('=', (4 - s.Length % 4) % 4);
        return Encoding.UTF8.GetString(Convert.FromBase64String(s));
    }

    private async Task AcceptLoop()
    {
        while (!_cts.IsCancellationRequested)
        {
            HttpListenerContext ctx;
            try { ctx = await _listener.GetContextAsync(); }
            catch { return; }
            _ = Task.Run(() => Handle(ctx));
        }
    }

    private async Task Handle(HttpListenerContext ctx)
    {
        try
        {
            var path = ctx.Request.Url!.AbsolutePath;
            if (!path.StartsWith("/p/")) { ctx.Response.StatusCode = 404; return; }
            var upstream = new Uri(Decode(path[3..]));
            using var req = new HttpRequestMessage(HttpMethod.Get, upstream);
            foreach (var (k, v) in _headers) req.Headers.TryAddWithoutValidation(k, v);
            if (ctx.Request.Headers["Range"] is { } range) req.Headers.TryAddWithoutValidation("Range", range);

            using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, _cts.Token);
            var final = resp.RequestMessage?.RequestUri ?? upstream;
            ctx.Response.StatusCode = (int)resp.StatusCode;
            var type = resp.Content.Headers.ContentType?.MediaType ?? "";

            if (resp.IsSuccessStatusCode && IsPlaylist(final, type))
            {
                var body = await resp.Content.ReadAsStringAsync(_cts.Token);
                var rewritten = Encoding.UTF8.GetBytes(Rewrite(body, final));
                ctx.Response.ContentType = "application/vnd.apple.mpegurl";
                ctx.Response.ContentLength64 = rewritten.Length;
                await ctx.Response.OutputStream.WriteAsync(rewritten, _cts.Token);
            }
            else
            {
                if (type.Length > 0) ctx.Response.ContentType = type;
                if (resp.Content.Headers.ContentRange is { } cr) ctx.Response.AddHeader("Content-Range", cr.ToString());
                if (resp.Content.Headers.ContentLength is { } len) ctx.Response.ContentLength64 = len;
                await using var src = await resp.Content.ReadAsStreamAsync(_cts.Token);
                await src.CopyToAsync(ctx.Response.OutputStream, _cts.Token);
            }
        }
        catch (Exception) when (!_cts.IsCancellationRequested)
        {
            try { ctx.Response.StatusCode = 502; } catch { }
        }
        catch (Exception) { }
        finally
        {
            try { ctx.Response.Close(); } catch { }
        }
    }

    private static bool IsPlaylist(Uri url, string type) =>
        url.AbsolutePath.EndsWith(".m3u8", StringComparison.OrdinalIgnoreCase)
        || type.Contains("mpegurl", StringComparison.OrdinalIgnoreCase);

    /// Cada URL (líneas sueltas y `URI="…"` de EXT-X-KEY / EXT-X-MAP / EXT-X-MEDIA) pasa a ser local.
    private string Rewrite(string playlist, Uri baseUrl)
    {
        var sb = new StringBuilder();
        foreach (var raw in playlist.Replace("\r\n", "\n").Split('\n'))
        {
            var line = raw;
            if (line.Length == 0) { sb.Append('\n'); continue; }
            if (line.StartsWith('#'))
            {
                line = System.Text.RegularExpressions.Regex.Replace(line, "URI=\"([^\"]+)\"",
                    m => $"URI=\"{Wrap(new Uri(baseUrl, m.Groups[1].Value))}\"");
            }
            else line = Wrap(new Uri(baseUrl, line.Trim())).AbsoluteUri;
            sb.Append(line).Append('\n');
        }
        return sb.ToString();
    }

    public void Dispose()
    {
        _cts.Cancel();
        try { _listener.Stop(); _listener.Close(); } catch { }
        _http.Dispose();
    }
}
