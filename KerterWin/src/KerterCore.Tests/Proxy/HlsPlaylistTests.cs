using KerterCore.Proxy;

namespace KerterCore.Tests.Proxy;

public class HlsPlaylistTests
{
    static readonly Uri Base = new("http://example.com/live/master.m3u8");

    [Fact]
    public void Master_SortsByBandwidth_AndDropsAudioOnly()
    {
        const string text = """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2"
            hi/index.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=640x360
            lo/index.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=64000
            audio/index.m3u8
            """;
        var master = Assert.IsType<Hls.MasterPlaylist>(Hls.Parse(text, Base));
        Assert.Null(master.Unsupported);
        Assert.Equal(new[] { 500000.0, 2000000.0 }, master.Variants.Select(v => v.Bandwidth));
        Assert.Equal(360, master.Variants[0].Height);
        Assert.Equal(1280, master.Variants[1].Width);
        Assert.Equal("http://example.com/live/lo/index.m3u8", master.Variants[0].Url.AbsoluteUri);
    }

    [Fact]
    public void Master_SeparateAudioTrack_IsUnsupported()
    {
        const string text = """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="audio.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=640x360,AUDIO="a"
            v.m3u8
            """;
        var master = Assert.IsType<Hls.MasterPlaylist>(Hls.Parse(text, Base));
        Assert.Equal("audio en pista aparte", master.Unsupported);
    }

    [Fact]
    public void Media_ParsesSegmentsSequenceAndDiscontinuity()
    {
        const string text = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:100\n"
            + "#EXT-X-INDEPENDENT-SEGMENTS\n#EXTINF:3.5,\na.ts\n#EXT-X-DISCONTINUITY\n#EXTINF:4.000,title\n/abs/b.ts\n";
        var media = Assert.IsType<Hls.MediaPlaylist>(Hls.Parse(text, Base));
        Assert.Equal(100, media.FirstSequence);
        Assert.Equal(101, media.LastSequence);
        Assert.Equal(4, media.TargetDuration);
        Assert.True(media.IndependentSegments);
        Assert.False(media.IsEnded);
        Assert.Equal(3.5, media.Segments[0].Duration);
        Assert.False(media.Segments[0].Discontinuity);
        Assert.True(media.Segments[1].Discontinuity);
        Assert.Equal("http://example.com/abs/b.ts", media.Segment(101)!.Url.AbsoluteUri);
        Assert.Null(media.Segment(99));
        Assert.Null(media.Segment(102));
    }

    [Theory]
    [InlineData("#EXT-X-ENDLIST", true, null)]
    [InlineData("#EXT-X-KEY:METHOD=AES-128,URI=\"k\"", false, "cifrado")]
    [InlineData("#EXT-X-KEY:METHOD=NONE", false, null)]
    [InlineData("#EXT-X-MAP:URI=\"init.mp4\"", false, "fMP4")]
    [InlineData("#EXT-X-BYTERANGE:100@0", false, "byte ranges")]
    public void Media_FlagsEndedAndUnsupported(string tag, bool ended, string? unsupported)
    {
        var text = $"#EXTM3U\n#EXT-X-TARGETDURATION:2\n{tag}\n#EXTINF:2,\ns.ts\n";
        var media = Assert.IsType<Hls.MediaPlaylist>(Hls.Parse(text, Base));
        Assert.Equal(ended, media.IsEnded);
        Assert.Equal(unsupported, media.Unsupported);
    }

    [Fact]
    public void NotAPlaylist_ReturnsNull() => Assert.Null(Hls.Parse("<html></html>", Base));

    [Fact]
    public void Attributes_HandlesQuotedCommas()
    {
        var attrs = Hls.Attributes("#EXT-X-STREAM-INF:BANDWIDTH=123,CODECS=\"a,b\",RESOLUTION=1x2");
        Assert.Equal("123", attrs["BANDWIDTH"]);
        Assert.Equal("a,b", attrs["CODECS"]);
        Assert.Equal("1x2", attrs["RESOLUTION"]);
    }

    [Theory]
    [InlineData("bytes=0-9", 100, 0, 9)]
    [InlineData("bytes=90-", 100, 90, 99)]
    [InlineData("bytes=-10", 100, 90, 99)]
    [InlineData("bytes=50-500", 100, 50, 99)]
    public void ByteRange_Valid(string header, int count, int lower, int upper) =>
        Assert.Equal((lower, upper), LocalHttpServer.ByteRange(header, count));

    [Theory]
    [InlineData("bytes=100-", 100)]
    [InlineData("items=0-1", 100)]
    [InlineData("bytes=5-2", 100)]
    public void ByteRange_Invalid(string header, int count) =>
        Assert.Null(LocalHttpServer.ByteRange(header, count));
}
