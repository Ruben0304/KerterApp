import Foundation

/// Qué deportes se muestran en Inicio (en vivo, competiciones, rieles) — para
/// no llenar la home de deportes que no interesan. Guardado en UserDefaults
/// como texto separado por comas (vía `@AppStorage`).
enum SportsFilterSettings {
    static let key = "enabledSports"

    /// Deportes que puede traer la cartelera del backend, en el mismo orden
    /// que ya usa la pantalla "Canales".
    static let allSports = ["Fútbol", "Tenis", "Baloncesto", "Deporte motor",
                            "Motociclismo", "Boxeo", "UFC", "Béisbol", "Otros"]

    /// Todos habilitados — el valor por defecto la primera vez que se abre la app.
    static let defaultRaw = allSports.joined(separator: ",")

    static func enabledSet(from raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map(String.init))
    }

    private static func folded(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lleva el deporte que manda el backend a uno de `allSports`. La cartelera
    /// mezcla idiomas ("soccer", "Béisbol") y a veces se equivoca (Laver Cup
    /// llega como "soccer" con la liga "Tenis"); sin esto, el filtro de Ajustes
    /// descarta partidos de fútbol enteros por llamarse distinto.
    static func canonicalSport(_ sport: String?, league: String?) -> String? {
        // Una liga que es el nombre de un deporte ("Tenis") manda sobre el campo deporte.
        if let league, let named = allSports.first(where: { $0 != "Otros" && folded($0) == folded(league) }) {
            return named
        }
        guard let sport, !sport.isEmpty else { return nil }
        let s = folded(sport)
        if s.contains("americano") || s.contains("american") || s.contains("nfl") { return "Otros" }
        let table: [(String, String)] = [
            ("soccer", "Fútbol"), ("futbol", "Fútbol"), ("football", "Fútbol"),
            ("tennis", "Tenis"), ("tenis", "Tenis"),
            ("basket", "Baloncesto"), ("baloncesto", "Baloncesto"),
            ("baseball", "Béisbol"), ("beisbol", "Béisbol"),
            ("boxing", "Boxeo"), ("boxeo", "Boxeo"),
            ("mma", "UFC"), ("ufc", "UFC"),
            ("motorcycl", "Motociclismo"), ("motociclismo", "Motociclismo"), ("motogp", "Motociclismo"),
            ("motor", "Deporte motor"), ("racing", "Deporte motor"), ("formula", "Deporte motor"),
        ]
        return table.first { s.contains($0.0) }?.1 ?? "Otros"
    }

    /// Orden estable (el de `allSports`), no el orden interno del `Set`.
    static func raw(from set: Set<String>) -> String {
        allSports.filter(set.contains).joined(separator: ",")
    }
}
