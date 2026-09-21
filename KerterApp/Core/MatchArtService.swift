import Foundation

/// Portada oficial de un partido concreto desde TheSportsDB (`strThumb`, 16:9).
/// Solo los partidos grandes suelen tenerla; si no hay, la app compone su
/// propia portada (estadio + jugadores) o usa los colores de los equipos.
///
/// Usa la clave pública de pruebas ("3"), que tiene límite de peticiones: por
/// eso solo se pide para el hero y la ficha, y todo queda en caché.
enum MatchArtService {

    private static let apiKey = "3"

    private struct Response: Decodable {
        let event: [Event]?
        struct Event: Decodable {
            let dateEvent: String?
            let strThumb: String?
            let strFanart: String?
            let strPoster: String?
        }
    }

    /// Busca "Local vs Visitante" (y al revés) y devuelve la portada del partido
    /// cuya fecha esté a ±3 días de hoy, para no usar arte de otra temporada.
    static func cover(home: String, away: String, near date: Date = Date()) async -> URL? {
        let home = home.trimmingCharacters(in: .whitespaces)
        let away = away.trimmingCharacters(in: .whitespaces)
        guard !home.isEmpty, !away.isEmpty else { return nil }

        let key = "\(home)|\(away)".lowercased()
        if let cached = await MatchArtCache.shared.value(for: key) { return cached }

        var queries = ["\(home) vs \(away)", "\(away) vs \(home)"]
        let folded = queries.map {
            $0.folding(options: .diacriticInsensitive, locale: Locale(identifier: "es"))
        }
        for q in folded where !queries.contains(q) { queries.append(q) }

        var found: URL?
        for query in queries {
            if let url = await search(query, near: date) {
                found = url
                break
            }
        }
        await MatchArtCache.shared.store(found, for: key)
        return found
    }

    private static func search(_ title: String, near date: Date) async -> URL? {
        let slug = title.replacingOccurrences(of: " ", with: "_")
        guard let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string:
                "https://www.thesportsdb.com/api/v1/json/\(apiKey)/searchevents.php?e=\(encoded)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(Response.self, from: data),
              let events = response.event else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")

        let candidates = events.compactMap { event -> (distance: TimeInterval, url: URL)? in
            guard let day = event.dateEvent.flatMap(formatter.date(from:)) else { return nil }
            let distance = abs(day.timeIntervalSince(date))
            guard distance <= 3 * 86_400 else { return nil }
            let art = [event.strThumb, event.strFanart, event.strPoster]
                .compactMap { $0 }
                .first { !$0.isEmpty }
            guard let art, let artURL = URL(string: art) else { return nil }
            return (distance, artURL)
        }
        return candidates.min { $0.distance < $1.distance }?.url
    }
}

/// Recuerda también los "no hay portada" para no repetir búsquedas.
private actor MatchArtCache {
    static let shared = MatchArtCache()
    private var store: [String: URL?] = [:]

    /// `nil` = nunca buscado; `.some(nil)` = buscado y sin portada.
    func value(for key: String) -> URL?? { store[key] }

    func store(_ url: URL?, for key: String) { store[key] = .some(url) }
}
