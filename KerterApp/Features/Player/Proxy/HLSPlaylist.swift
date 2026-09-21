import Foundation

/// Lectura mínima de playlists HLS: lo justo para grabar un directo en TS.
/// Lo que el grabador no sabe manejar (cifrado, fMP4, byte ranges, audio en
/// pistas aparte) se marca para que el reproductor vaya directo al servidor.
enum HLS {
    struct Variant: Equatable {
        let bandwidth: Double    // BANDWIDTH (pico), en bits por segundo
        let width: Int
        let height: Int
        let url: URL
    }

    struct Segment {
        let sequence: Int
        let duration: Double
        let url: URL
        /// Hay un #EXT-X-DISCONTINUITY justo antes (reinicio del codificador…).
        let discontinuity: Bool
    }

    struct MediaPlaylist {
        let url: URL
        let targetDuration: Double
        let mediaSequence: Int
        let segments: [Segment]
        let isEnded: Bool
        let independentSegments: Bool
        /// Algo que el grabador no cubre (cifrado, fMP4, byte ranges).
        let unsupported: String?

        var firstSequence: Int { mediaSequence }
        var lastSequence: Int { mediaSequence + segments.count - 1 }

        func segment(_ sequence: Int) -> Segment? {
            let index = sequence - mediaSequence
            return segments.indices.contains(index) ? segments[index] : nil
        }
    }

    enum Playlist {
        case master([Variant], unsupported: String?)
        case media(MediaPlaylist)
    }

    static func parse(_ text: String, url: URL) -> Playlist? {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.first?.hasPrefix("#EXTM3U") == true else { return nil }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }) {
            return parseMaster(lines, url: url)
        }
        return .media(parseMedia(lines, url: url))
    }

    private static func parseMaster(_ lines: [String], url: URL) -> Playlist {
        var variants: [Variant] = []
        var unsupported: String?
        var pending: [String: String]?
        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributes(of: line)
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let attrs = attributes(of: line)
                // Audio (o subtítulos) en pistas aparte: el grabador solo lleva una.
                if attrs["URI"] != nil, attrs["TYPE"] == "AUDIO" { unsupported = "audio en pista aparte" }
            } else if !line.hasPrefix("#"), let attrs = pending {
                pending = nil
                guard let variantURL = URL(string: line, relativeTo: url)?.absoluteURL else { continue }
                let size = (attrs["RESOLUTION"] ?? "").split(separator: "x").compactMap { Int($0) }
                variants.append(Variant(bandwidth: Double(attrs["BANDWIDTH"] ?? "") ?? 0,
                                        width: size.count == 2 ? size[0] : 0,
                                        height: size.count == 2 ? size[1] : 0,
                                        url: variantURL))
            }
        }
        // Si hay variantes con video, fuera las de solo audio.
        if variants.contains(where: { $0.height > 0 }) {
            variants.removeAll { $0.height == 0 }
        }
        return .master(variants.sorted { $0.bandwidth < $1.bandwidth }, unsupported: unsupported)
    }

    private static func parseMedia(_ lines: [String], url: URL) -> MediaPlaylist {
        var target = 0.0, sequence = 0, ended = false, independent = false
        var unsupported: String?
        var segments: [Segment] = []
        var duration: Double?
        var discontinuity = false

        for line in lines {
            if let value = line.value(after: "#EXT-X-TARGETDURATION:") {
                target = Double(value) ?? 0
            } else if let value = line.value(after: "#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(value) ?? 0
            } else if let value = line.value(after: "#EXTINF:") {
                duration = Double(value.split(separator: ",").first ?? "")
            } else if line == "#EXT-X-DISCONTINUITY" {
                discontinuity = true
            } else if line == "#EXT-X-ENDLIST" || line == "#EXT-X-PLAYLIST-TYPE:VOD" {
                ended = true
            } else if line == "#EXT-X-INDEPENDENT-SEGMENTS" {
                independent = true
            } else if line.hasPrefix("#EXT-X-BYTERANGE") {
                unsupported = "byte ranges"
            } else if line.hasPrefix("#EXT-X-MAP") {
                unsupported = "fMP4"
            } else if line.hasPrefix("#EXT-X-KEY:"), attributes(of: line)["METHOD"] != "NONE" {
                unsupported = "cifrado"
            } else if !line.hasPrefix("#"), let segmentURL = URL(string: line, relativeTo: url)?.absoluteURL {
                segments.append(Segment(sequence: sequence + segments.count,
                                        duration: duration ?? target,
                                        url: segmentURL,
                                        discontinuity: discontinuity))
                duration = nil
                discontinuity = false
            }
        }
        return MediaPlaylist(url: url, targetDuration: max(target, 1), mediaSequence: sequence,
                             segments: segments, isEnded: ended, independentSegments: independent,
                             unsupported: unsupported)
    }

    /// `KEY=valor,OTRA="con, comas"` → diccionario.
    static func attributes(of line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        var result: [String: String] = [:]
        var key = "", value = "", inKey = true, inQuotes = false
        for ch in line[line.index(after: colon)...] {
            if inKey {
                if ch == "=" { inKey = false } else if ch != "," { key.append(ch) }
            } else if ch == "\"" {
                inQuotes.toggle()
            } else if ch == ",", !inQuotes {
                result[key.trimmingCharacters(in: .whitespaces)] = value
                key = ""
                value = ""
                inKey = true
            } else {
                value.append(ch)
            }
        }
        if !key.isEmpty { result[key.trimmingCharacters(in: .whitespaces)] = value }
        return result
    }
}

private extension String {
    func value(after prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
