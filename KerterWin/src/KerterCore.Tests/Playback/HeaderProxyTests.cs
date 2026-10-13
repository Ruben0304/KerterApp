using System.Net;
using KerterCore.Playback;
using Xunit;

namespace KerterCore.Tests.Playback;

public class HeaderProxyTests
{
    [Fact]
    public async Task Injects_headers_and_rewrites_playlist()
    {
        var seen = new List<(string Path, string? Origin, string? Referer)>();
        using var upstream = new HttpListener();
        var port = new Random().Next(20000, 40000);
        upstream.Prefixes.Add($"http://127.0.0.1:{port}/");
        upstream.Start();
        _ = Task.Run(async () =>
        {
            while (true)
            {
                var ctx = await upstream.GetContextAsync();
                seen.Add((ctx.Request.Url!.AbsolutePath, ctx.Request.Headers["Origin"], ctx.Request.Headers["Referer"]));
                var body = ctx.Request.Url.AbsolutePath == "/a/master.m3u8"
                    ? "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"../key.bin\"\n#EXTINF:2,\nseg1.ts\n"u8.ToArray()
                    : new byte[] { 1, 2, 3, 4 };
                if (ctx.Request.Url.AbsolutePath.EndsWith(".m3u8")) ctx.Response.ContentType = "application/vnd.apple.mpegurl";
                await ctx.Response.OutputStream.WriteAsync(body);
                ctx.Response.Close();
            }
        });

        using var proxy = new HeaderProxy(new Dictionary<string, string> { ["Origin"] = "https://embed.test", ["Referer"] = "https://embed.test/" });
        using var http = new HttpClient();
        var playlist = await http.GetStringAsync(proxy.Wrap(new Uri($"http://127.0.0.1:{port}/a/master.m3u8")));
        Assert.DoesNotContain("seg1.ts\n", playlist.Replace("127.0.0.1", ""));
        var lines = playlist.Split('\n', StringSplitOptions.RemoveEmptyEntries);
        var segUrl = lines.First(l => !l.StartsWith('#'));
        Assert.StartsWith("http://127.0.0.1:", segUrl);
        var keyUrl = System.Text.RegularExpressions.Regex.Match(playlist, "URI=\"([^\"]+)\"").Groups[1].Value;
        Assert.Equal(new byte[] { 1, 2, 3, 4 }, await http.GetByteArrayAsync(segUrl));
        Assert.Equal(new byte[] { 1, 2, 3, 4 }, await http.GetByteArrayAsync(keyUrl));
        Assert.All(seen, s => { Assert.Equal("https://embed.test", s.Origin); Assert.Equal("https://embed.test/", s.Referer); });
        Assert.Contains(seen, s => s.Path == "/a/seg1.ts");
        Assert.Contains(seen, s => s.Path == "/key.bin");
    }
}
