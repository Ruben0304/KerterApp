using KerterCore.Models;
using KerterCore.Strikeout;
using KerterCore.Util;
using Xunit;
using Xunit.Abstractions;

namespace KerterCore.Tests;

public class CoreTests(ITestOutputHelper output)
{
    [Fact]
    public void Teams_match_across_languages()
    {
        Assert.True(Text.SimilarTeam("Italy", "Italia"));
        Assert.True(Text.SimilarTeam("Belgium", "Bélgica"));
        Assert.False(Text.SimilarTeam("Irlanda", "Northern Ireland"));
        Assert.True(Text.SimilarTeam("Real Madrid CF", "Real Madrid"));
        Assert.False(Text.SimilarTeam("Real Madrid", "Real Sociedad"));
    }

    [Fact]
    public void Group_assignments()
    {
        var a = new[]
        {
            new Assignment("1", "Real Madrid at Elche", "LaLiga", "soccer", "20:45", null, 5, "Kerter+ 1 HD", null, null, null, false),
            new Assignment("1", "Real Madrid at Elche", "LaLiga", "soccer", "20:45", null, 6, "ESPN", null, null, null, false),
            new Assignment("2", "X at Y", "LaLiga", "soccer", "20:45", null, 7, "Z", null, null, null, true),
        };
        var ev = LiveEvent.Group(a);
        Assert.Single(ev);
        Assert.Equal("Elche vs Real Madrid", ev[0].Title);
        Assert.Equal(2, ev[0].Channels.Count);
        Assert.True(ev[0].Channels[0].IsKerterPlus);
        Assert.Equal(1, ev[0].Channels[0].QualityRank);
        Assert.Equal(20, ev[0].ScheduledStart!.Value.Hour);
    }

    [Fact]
    public void Drm_key_formats()
    {
        Assert.Equal("00112233445566778899aabbccddeeff", DrmKeys.CanonicalHex("00112233-4455-6677-8899-aabbccddeeff"));
        Assert.Null(DrmKeys.CanonicalHex("zz"));
    }

    [Fact]
    public async Task Strikeout_live_resolves_hls()
    {
        var events = await StrikeoutSite.ScheduleAsync(StrikeoutSite.Sports[0]);
        output.WriteLine($"{events.Count} eventos");
        foreach (var e in events.Take(5)) output.WriteLine($"{e.Start} {e.Title} {e.Path}");
        Assert.NotEmpty(events);
        foreach (var ev in events.Where(e => e.Start != null && (e.Start.Value - DateTimeOffset.UtcNow).TotalMinutes is > -100 and < 30).Take(3))
        {
            var streams = await StrikeoutSite.StreamsAsync(ev);
            output.WriteLine($"{ev.Title}: {string.Join(", ", streams.Select(s => s.Label))}");
            try
            {
                var n = await NativeStream.ResolveAsync(streams[0].Url);
                output.WriteLine("MASTER " + n.MasterUrl);
                await n.RefreshAsync();
                using var req = new HttpRequestMessage(HttpMethod.Get, n.MasterUrl);
                foreach (var (k, v) in n.Headers) req.Headers.TryAddWithoutValidation(k, v);
                using var resp = await new HttpClient().SendAsync(req);
                var body = await resp.Content.ReadAsStringAsync();
                output.WriteLine($"{(int)resp.StatusCode} {body[..Math.Min(300, body.Length)]}");
                return;
            }
            catch (NativeException ex) { output.WriteLine($"{ex.Reason}: {ex.Message}"); }
        }
    }
}
