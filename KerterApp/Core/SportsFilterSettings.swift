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

    /// Orden estable (el de `allSports`), no el orden interno del `Set`.
    static func raw(from set: Set<String>) -> String {
        allSports.filter(set.contains).joined(separator: ",")
    }
}
