using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using KerterCore.Proxy;

namespace KerterCore.Tests.Proxy;

/// Servidor HLS falso: directo con 3 variantes, ventana de 6 fragmentos de 1 s
/// y fragmentos .ts sintéticos (bytes deterministas según calidad y número).
sealed class FakeHlsServer : IDisposable
{
    readonly HttpListener listener = new();
    readonly Stopwatch clock = Stopwatch.StartNew();
    public string Prefix { get; }
    public const int SegmentSize = 30_000;
    public int MasterRequests, PlaylistRequests, SegmentRequests;
    public readonly List<string> UserAgents = new();
    public string? LastCustomHeader;

    public FakeHlsServer()
    {
        var probe = new TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        var port = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        Prefix = $"http://127.0.0.1:{port}/";
        listener.Prefixes.Add(Prefix);
        listener.Start();
        _ = Task.Run(Loop);
    }

    public static byte[] SegmentBytes(int variant, int sequence)
    {
        var data = new byte[SegmentSize];
        new Random(variant * 100000 + sequence).NextBytes(data);
        data[0] = 0x47;
        return data;
    }

    async Task Loop()
    {
        while (listener.IsListening)
        {
            HttpListenerContext ctx;
            try { ctx = await listener.GetContextAsync(); } catch { return; }
            _ = Task.Run(() => Handle(ctx));
        }
    }

    void Handle(HttpListenerContext ctx)
    {
        try
        {
            var path = ctx.Request.Url!.AbsolutePath;
            lock (UserAgents)
            {
                UserAgents.Add(ctx.Request.UserAgent ?? "");
                LastCustomHeader = ctx.Request.Headers["X-Test"];
            }
            byte[] body;
            string type;
            if (path == "/master.m3u8")
            {
                Interlocked.Increment(ref MasterRequests);
                type = "application/vnd.apple.mpegurl";
                body = System.Text.Encoding.UTF8.GetBytes(
                    "#EXTM3U\n"
                    + "#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720\nv2/index.m3u8\n"
                    + "#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=426x240\nv0/index.m3u8\n"
                    + "#EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=854x480\nv1/index.m3u8\n");
            }
            else if (path.EndsWith("/index.m3u8"))
            {
                Interlocked.Increment(ref PlaylistRequests);
                var variant = path[2] - '0';
                var last = 10 + (int)clock.Elapsed.TotalSeconds;
                var first = last - 5;
                var text = $"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:{first}\n";
                for (var s = first; s <= last; s++) text += $"#EXTINF:1.000,\nseg{s}.ts\n";
                type = "application/vnd.apple.mpegurl";
                body = System.Text.Encoding.UTF8.GetBytes(text);
            }
            else if (path.Contains("/seg") && path.EndsWith(".ts"))
            {
                Interlocked.Increment(ref SegmentRequests);
                var variant = path[2] - '0';
                var seq = int.Parse(path[(path.LastIndexOf("/seg") + 4)..^3]);
                type = "video/mp2t";
                body = SegmentBytes(variant, seq);
                if (ctx.Request.Headers["Range"] is { } range && range.StartsWith("bytes="))
                {
                    var parts = range[6..].Split('-');
                    var lo = int.Parse(parts[0]);
                    var hi = parts[1].Length == 0 ? body.Length - 1 : Math.Min(int.Parse(parts[1]), body.Length - 1);
                    ctx.Response.StatusCode = 206;
                    ctx.Response.Headers["Content-Range"] = $"bytes {lo}-{hi}/{body.Length}";
                    body = body[lo..(hi + 1)];
                }
            }
            else
            {
                ctx.Response.StatusCode = 404;
                ctx.Response.Close();
                return;
            }
            ctx.Response.ContentType = type;
            ctx.Response.ContentLength64 = body.Length;
            ctx.Response.OutputStream.Write(body);
            ctx.Response.Close();
        }
        catch { try { ctx.Response.Abort(); } catch { } }
    }

    public void Dispose()
    {
        try { listener.Stop(); listener.Close(); } catch { }
    }
}

public class LiveProxyIntegrationTests
{
    [Fact]
    public async Task Records_ServesLocalPlaylistAndSegments_AndCleansUp()
    {
        using var fake = new FakeHlsServer();
        var source = new Uri(fake.Prefix + "master.m3u8");
        var statuses = new List<LiveProxy.Status>();
        var headers = new Dictionary<string, string> { ["X-Test"] = "hola" };
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(40));

        var proxy = await LiveProxy.StartAsync(source, headers, s => { lock (statuses) statuses.Add(s); }, cts.Token);
        Assert.NotNull(proxy);
        using var _ = proxy;

        Assert.Equal(3, proxy!.Variants.Count);
        Assert.Equal(new[] { 240, 480, 720 }, proxy.Variants.Select(v => v.Height));
        Assert.NotNull(proxy.LocalUrl);
        Assert.Equal("127.0.0.1", proxy.LocalUrl!.Host);

        using var http = new HttpClient();
        var playlist = await http.GetStringAsync(proxy.LocalUrl);
        Assert.StartsWith("#EXTM3U", playlist);
        Assert.Contains("#EXT-X-MEDIA-SEQUENCE:", playlist);
        var segmentPaths = playlist.Split('\n').Where(l => l.StartsWith("/seg/")).ToList();
        Assert.True(segmentPaths.Count >= 3, playlist);

        var segUrl = new Uri(proxy.LocalUrl, segmentPaths[0]);
        var bytes = await http.GetByteArrayAsync(segUrl);
        Assert.Equal(FakeHlsServer.SegmentSize, bytes.Length);
        Assert.Equal(0x47, bytes[0]);
        // Arranca en la segunda calidad (índice 1 de 3).
        Assert.Equal(FakeHlsServer.SegmentBytes(1, SeqOfFirst(playlist, bytes)), bytes);

        // Range
        using var req = new HttpRequestMessage(HttpMethod.Get, segUrl);
        req.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(10, 19);
        using var partial = await http.SendAsync(req);
        Assert.Equal(HttpStatusCode.PartialContent, partial.StatusCode);
        Assert.Equal(bytes[10..20], await partial.Content.ReadAsByteArrayAsync());

        Assert.Equal(HttpStatusCode.NotFound, (await http.GetAsync(new Uri(proxy.LocalUrl, "/seg/99999.ts"))).StatusCode);

        // Las cabeceras personalizadas llegan al servidor.
        lock (fake.UserAgents) Assert.Equal("hola", fake.LastCustomHeader);

        // El estado se publica.
        await Task.Delay(1500);
        lock (statuses) Assert.NotEmpty(statuses);

        // La playlist crece con el directo.
        await Task.Delay(2500);
        var later = await http.GetStringAsync(proxy.LocalUrl);
        Assert.True(later.Split('\n').Count(l => l.StartsWith("/seg/")) > segmentPaths.Count);

        // Al parar se borra la carpeta y el servidor local se cierra.
        proxy.Stop();
        await proxy.Completion.WaitAsync(TimeSpan.FromSeconds(10));
        await Assert.ThrowsAnyAsync<HttpRequestException>(() => http.GetStringAsync(proxy.LocalUrl));
    }

    // El primer fragmento local es el número de segmento del servidor; se averigua probando.
    static int SeqOfFirst(string playlist, byte[] bytes)
    {
        for (var s = 0; s < 200; s++)
            if (FakeHlsServer.SegmentBytes(1, s).AsSpan().SequenceEqual(bytes)) return s;
        return -1;
    }

    [Fact]
    public async Task Vod_IsNotRecorded_ReturnsNull()
    {
        using var vod = new VodServer();
        var proxy = await LiveProxy.StartAsync(new Uri(vod.Url), null, _ => { }, CancellationToken.None);
        Assert.Null(proxy);
    }

    [Fact]
    public async Task Cancellation_ReturnsNull()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        var proxy = await LiveProxy.StartAsync(new Uri("http://127.0.0.1:1/x.m3u8"), null, _ => { }, cts.Token);
        Assert.Null(proxy);
    }

    sealed class VodServer : IDisposable
    {
        readonly HttpListener l = new();
        public string Url { get; }
        public VodServer()
        {
            var p = new TcpListener(IPAddress.Loopback, 0);
            p.Start();
            var port = ((IPEndPoint)p.LocalEndpoint).Port;
            p.Stop();
            Url = $"http://127.0.0.1:{port}/vod.m3u8";
            l.Prefixes.Add($"http://127.0.0.1:{port}/");
            l.Start();
            _ = Task.Run(async () =>
            {
                while (l.IsListening)
                {
                    HttpListenerContext c;
                    try { c = await l.GetContextAsync(); } catch { return; }
                    var b = System.Text.Encoding.UTF8.GetBytes("#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\ns.ts\n#EXT-X-ENDLIST\n");
                    c.Response.OutputStream.Write(b);
                    c.Response.Close();
                }
            });
        }
        public void Dispose() { try { l.Stop(); l.Close(); } catch { } }
    }
}
