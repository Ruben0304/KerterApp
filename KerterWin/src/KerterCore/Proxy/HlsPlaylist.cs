using System.Globalization;

namespace KerterCore.Proxy;

/// Una calidad de la playlist maestra.
/// Bandwidth = BANDWIDTH (pico), en bits por segundo.
public sealed record Variant(double Bandwidth, int Width, int Height, Uri Url);

/// Lectura mínima de playlists HLS: lo justo para grabar un directo en TS.
/// Lo que el grabador no sabe manejar (cifrado, fMP4, byte ranges, audio en
/// pistas aparte) se marca para que el reproductor vaya directo al servidor.
public static class Hls
{
    public sealed record Segment(
        int Sequence,
        double Duration,
        Uri Url,
        // Hay un #EXT-X-DISCONTINUITY justo antes (reinicio del codificador…).
        bool Discontinuity);

    public abstract record Playlist;

    public sealed record MasterPlaylist(IReadOnlyList<Variant> Variants, string? Unsupported) : Playlist;

    public sealed record MediaPlaylist(
        Uri Url,
        double TargetDuration,
        int MediaSequence,
        IReadOnlyList<Segment> Segments,
        bool IsEnded,
        bool IndependentSegments,
        // Algo que el grabador no cubre (cifrado, fMP4, byte ranges).
        string? Unsupported) : Playlist
    {
        public int FirstSequence => MediaSequence;
        public int LastSequence => MediaSequence + Segments.Count - 1;

        public Segment? Segment(int sequence)
        {
            var index = sequence - MediaSequence;
            return index >= 0 && index < Segments.Count ? Segments[index] : null;
        }
    }

    public static Playlist? Parse(string text, Uri url)
    {
        var lines = text.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(l => l.Trim().TrimStart('﻿'))
            .Where(l => l.Length > 0)
            .ToList();
        if (lines.Count == 0 || !lines[0].StartsWith("#EXTM3U", StringComparison.Ordinal)) return null;
        if (lines.Any(l => l.StartsWith("#EXT-X-STREAM-INF:", StringComparison.Ordinal)))
            return ParseMaster(lines, url);
        return ParseMedia(lines, url);
    }

    static Uri? Resolve(string line, Uri baseUrl) =>
        Uri.TryCreate(baseUrl, line, out var u) ? u : null;

    static Playlist ParseMaster(List<string> lines, Uri url)
    {
        var variants = new List<Variant>();
        string? unsupported = null;
        Dictionary<string, string>? pending = null;
        foreach (var line in lines)
        {
            if (line.StartsWith("#EXT-X-STREAM-INF:", StringComparison.Ordinal))
            {
                pending = Attributes(line);
            }
            else if (line.StartsWith("#EXT-X-MEDIA:", StringComparison.Ordinal))
            {
                var attrs = Attributes(line);
                // Audio (o subtítulos) en pistas aparte: el grabador solo lleva una.
                if (attrs.ContainsKey("URI") && attrs.GetValueOrDefault("TYPE") == "AUDIO")
                    unsupported = "audio en pista aparte";
            }
            else if (!line.StartsWith('#') && pending is { } attrs)
            {
                pending = null;
                var variantUrl = Resolve(line, url);
                if (variantUrl == null) continue;
                var size = attrs.GetValueOrDefault("RESOLUTION", "").Split('x')
                    .Select(s => int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var n) ? (int?)n : null)
                    .Where(n => n != null).Select(n => n!.Value).ToArray();
                double.TryParse(attrs.GetValueOrDefault("BANDWIDTH", ""), NumberStyles.Float, CultureInfo.InvariantCulture, out var bw);
                variants.Add(new Variant(bw, size.Length == 2 ? size[0] : 0, size.Length == 2 ? size[1] : 0, variantUrl));
            }
        }
        // Si hay variantes con video, fuera las de solo audio.
        if (variants.Any(v => v.Height > 0)) variants.RemoveAll(v => v.Height == 0);
        return new MasterPlaylist(variants.OrderBy(v => v.Bandwidth).ToList(), unsupported);
    }

    static MediaPlaylist ParseMedia(List<string> lines, Uri url)
    {
        double target = 0;
        int sequence = 0;
        bool ended = false, independent = false, discontinuity = false;
        string? unsupported = null;
        var segments = new List<Segment>();
        double? duration = null;

        foreach (var line in lines)
        {
            if (Value(line, "#EXT-X-TARGETDURATION:") is { } t)
                target = double.TryParse(t, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : 0;
            else if (Value(line, "#EXT-X-MEDIA-SEQUENCE:") is { } s)
                sequence = int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var n) ? n : 0;
            else if (Value(line, "#EXTINF:") is { } inf)
                duration = double.TryParse(inf.Split(',')[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : null;
            else if (line == "#EXT-X-DISCONTINUITY")
                discontinuity = true;
            else if (line == "#EXT-X-ENDLIST" || line == "#EXT-X-PLAYLIST-TYPE:VOD")
                ended = true;
            else if (line == "#EXT-X-INDEPENDENT-SEGMENTS")
                independent = true;
            else if (line.StartsWith("#EXT-X-BYTERANGE", StringComparison.Ordinal))
                unsupported = "byte ranges";
            else if (line.StartsWith("#EXT-X-MAP", StringComparison.Ordinal))
                unsupported = "fMP4";
            else if (line.StartsWith("#EXT-X-KEY:", StringComparison.Ordinal) && Attributes(line).GetValueOrDefault("METHOD") != "NONE")
                unsupported = "cifrado";
            else if (!line.StartsWith('#') && Resolve(line, url) is { } segmentUrl)
            {
                segments.Add(new Segment(sequence + segments.Count, duration ?? target, segmentUrl, discontinuity));
                duration = null;
                discontinuity = false;
            }
        }
        return new MediaPlaylist(url, Math.Max(target, 1), sequence, segments, ended, independent, unsupported);
    }

    static string? Value(string line, string prefix) =>
        line.StartsWith(prefix, StringComparison.Ordinal) ? line[prefix.Length..] : null;

    /// `KEY=valor,OTRA="con, comas"` → diccionario.
    public static Dictionary<string, string> Attributes(string line)
    {
        var result = new Dictionary<string, string>();
        var colon = line.IndexOf(':');
        if (colon < 0) return result;
        var key = new System.Text.StringBuilder();
        var value = new System.Text.StringBuilder();
        bool inKey = true, inQuotes = false;
        foreach (var ch in line[(colon + 1)..])
        {
            if (inKey)
            {
                if (ch == '=') inKey = false;
                else if (ch != ',') key.Append(ch);
            }
            else if (ch == '"') inQuotes = !inQuotes;
            else if (ch == ',' && !inQuotes)
            {
                result[key.ToString().Trim()] = value.ToString();
                key.Clear();
                value.Clear();
                inKey = true;
            }
            else value.Append(ch);
        }
        if (key.Length > 0) result[key.ToString().Trim()] = value.ToString();
        return result;
    }
}
