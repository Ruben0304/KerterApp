import Foundation

/// Resúmenes extendidos de YouTube para un partido — solo LaLiga y Champions,
/// que son las únicas ligas con resumen oficial fiable. Busca por nombre de
/// equipo dentro del canal de cada fuente (YouTube Data API v3, cuenta
/// gratis); el canal se localiza por nombre una vez por sesión en vez de
/// escribir su ID a mano.
enum YouTubeHighlightsService {

    private static let apiKey = "AIzaSyAcspIdEeG954gDDenlHHWPXqdMb3I-pWI"

    struct Highlight: Sendable, Hashable, Identifiable {
        let id: String            // id del video de YouTube
        let title: String
        let channelTitle: String
        let thumbnail: URL?
    }

    enum Source: String, Sendable, CaseIterable {
        case espn = "ESPN"
        case laliga = "LaLiga"
        case cbsGolazo = "CBS Golazo"

        /// Texto que debe contener el nombre del canal de YouTube para aceptar
        /// el resultado como de esta fuente. ESPN va con "deportes": solo
        /// "espn" también cazaba ESPN FC, que es el canal en inglés.
        fileprivate var channelMatch: [String] {
            switch self {
            case .espn: return ["espn deportes"]
            case .laliga: return ["laliga", "la liga"]
            case .cbsGolazo: return ["golazo"]
            }
        }

        /// Para encontrar el canal (no un video): de ahí salen su ID, para
        /// buscar el resumen solo dentro de él, y su logo para el selector.
        fileprivate var channelQuery: String {
            switch self {
            case .espn: return "ESPN Deportes"
            case .laliga: return "LaLiga EA Sports"
            case .cbsGolazo: return "CBS Sports Golazo"
            }
        }
    }

    /// Qué fuentes mostrar según la competición: en LaLiga, ESPN + LaLiga
    /// oficial; en Champions, ESPN + CBS Golazo (suben antes). El resto de
    /// ligas solo cuenta con ESPN Deportes.
    static func sources(forLeagueSlug slug: String?) -> [Source] {
        switch slug {
        case "esp.1": return [.espn, .laliga]
        case "uefa.champions": return [.espn, .cbsGolazo]
        // Otras ligas de fútbol conocidas (Premier, Serie A…): solo ESPN Deportes.
        case .some: return [.espn]
        case nil: return []
        }
    }

    /// Estado de la búsqueda de un resumen para una fuente concreta.
    enum LoadState: Equatable {
        case loading
        case found(Highlight)
        case unavailable
    }

    private struct SearchResponse: Decodable {
        let items: [Item]
        struct Item: Decodable {
            let id: VideoId
            let snippet: Snippet
            struct VideoId: Decodable { let videoId: String? }
            struct Snippet: Decodable {
                let title: String?
                let channelTitle: String?
                let thumbnails: Thumbnails?
                struct Thumbnails: Decodable {
                    let medium: Thumb?
                    struct Thumb: Decodable { let url: String? }
                }
            }
        }
    }

    /// Busca el resumen de "local vs visitante" solo dentro del canal de la
    /// fuente pedida y se queda con el resultado más relevante.
    static func highlight(for source: Source, home: String, away: String) async -> Highlight? {
        let key = "\(source.rawValue)|\(home)|\(away)"
        if let cached = await HighlightCache.shared.cached(key) { return cached }
        let fresh = await search(source: source, home: home, away: away)
        await HighlightCache.shared.remember(key, fresh)
        return fresh
    }

    private static func search(source: Source, home: String, away: String) async -> Highlight? {
        guard let channel = await channel(for: source) else { return nil }
        var comps = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")
        comps?.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "channelId", value: channel.id),
            URLQueryItem(name: "order", value: "relevance"),
            URLQueryItem(name: "maxResults", value: "1"),
            URLQueryItem(name: "q", value: "\(home) vs \(away) resumen"),
            URLQueryItem(name: "key", value: apiKey),
        ]
        guard let url = comps?.url else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(SearchResponse.self, from: data),
              let hit = response.items.first,
              let videoId = hit.id.videoId, !videoId.isEmpty else { return nil }
        return Highlight(
            id: videoId,
            title: hit.snippet.title ?? "",
            channelTitle: hit.snippet.channelTitle ?? source.rawValue,
            thumbnail: (hit.snippet.thumbnails?.medium?.url).flatMap(URL.init(string:))
        )
    }

    // MARK: - Canal de cada fuente (ID para buscar, logo para el selector)

    fileprivate struct Channel: Sendable {
        let id: String
        let logo: URL?
    }

    private struct ChannelSearchResponse: Decodable {
        let items: [Item]
        struct Item: Decodable {
            let id: ChannelId
            let snippet: Snippet
            struct ChannelId: Decodable { let channelId: String? }
            struct Snippet: Decodable {
                let title: String?
                let thumbnails: Thumbnails?
                struct Thumbnails: Decodable {
                    let medium: Thumb?
                    let normal: Thumb?
                    enum CodingKeys: String, CodingKey { case medium, normal = "default" }
                    struct Thumb: Decodable { let url: String? }
                }
            }
        }
    }

    /// El logo del canal de YouTube (no cambia con el partido) — el mismo que
    /// se ve en el selector de canales de un partido en vivo.
    static func logo(for source: Source) async -> URL? {
        await channel(for: source)?.logo
    }

    /// El canal no cambia: se cachea sin caducar durante la sesión — una sola
    /// consulta por fuente en total. Un fallo no se cachea, para reintentar.
    private static func channel(for source: Source) async -> Channel? {
        if let cached = await ChannelCache.shared.cached(source) { return cached }
        guard let fresh = await fetchChannel(source: source) else { return nil }
        await ChannelCache.shared.remember(source, fresh)
        return fresh
    }

    /// Primer canal de la búsqueda cuyo nombre coincide con la fuente — no
    /// el primero a secas, que para "ESPN Deportes" podría ser otro ESPN.
    private static func fetchChannel(source: Source) async -> Channel? {
        var comps = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")
        comps?.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "channel"),
            URLQueryItem(name: "maxResults", value: "5"),
            URLQueryItem(name: "q", value: source.channelQuery),
            URLQueryItem(name: "key", value: apiKey),
        ]
        guard let url = comps?.url else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(ChannelSearchResponse.self, from: data) else { return nil }
        let match = response.items.first { item in
            let title = (item.snippet.title ?? "")
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            return source.channelMatch.contains { title.contains($0) }
        }
        guard let match, let id = match.id.channelId, !id.isEmpty else { return nil }
        let thumb = match.snippet.thumbnails
        let href = thumb?.medium?.url ?? thumb?.normal?.url
        return Channel(id: id, logo: href.flatMap(URL.init(string:)))
    }
}

/// Un canal por fuente durante toda la sesión — son solo 3 posibles.
private actor ChannelCache {
    static let shared = ChannelCache()
    private var store: [YouTubeHighlightsService.Source: YouTubeHighlightsService.Channel] = [:]

    func cached(_ source: YouTubeHighlightsService.Source) -> YouTubeHighlightsService.Channel? {
        store[source]
    }

    func remember(_ source: YouTubeHighlightsService.Source, _ channel: YouTubeHighlightsService.Channel) {
        store[source] = channel
    }
}

/// Los encontrados se cachean sin caducar (el resumen de un partido pasado no
/// cambia); los "no encontrado" solo 10 minutos, para reintentar más tarde
/// sin gastar cuota de la API cada vez que se reabre la ficha.
private actor HighlightCache {
    static let shared = HighlightCache()
    private enum Entry { case hit(YouTubeHighlightsService.Highlight); case miss(Date) }
    private var store: [String: Entry] = [:]

    func cached(_ key: String) -> YouTubeHighlightsService.Highlight?? {
        switch store[key] {
        case .hit(let h): return .some(h)
        case .miss(let date) where Date().timeIntervalSince(date) < 600: return .some(nil)
        default: return nil
        }
    }

    func remember(_ key: String, _ highlight: YouTubeHighlightsService.Highlight?) {
        store[key] = highlight.map(Entry.hit) ?? .miss(Date())
    }
}
