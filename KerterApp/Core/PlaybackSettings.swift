import Foundation

/// Preferencias de reproducción guardadas en `UserDefaults` (vía `@AppStorage`).
enum PlaybackSettings {
    /// Segundos de margen con los que se ve el directo (y que se intentan
    /// tener descargados por delante).
    static let bufferKey = "liveBufferSeconds"
    static let defaultBuffer = 60
    static let bufferOptions = [60, 90, 120, 180, 300]

    /// Vistas previas en vivo (portada y ficha del partido). Consumen red: con
    /// una conexión justa conviene apagarlas.
    static let previewsKey = "autoplayPreviews"
    static let defaultPreviews = true
    /// Acelerador de conexión: el directo se graba en local con varias
    /// conexiones y el reproductor lee de ahí (ver `LiveProxy`).
    static let proxyKey = "connectionBooster"
    static let defaultProxy = true
    /// Al abrir un canal, esperar a tener grabado el margen completo.
    static let waitForMarginKey = "waitForMargin"
    static let defaultWaitForMargin = false

    static func label(_ seconds: Int) -> String {
        let minutes = seconds / 60, rest = seconds % 60
        switch (minutes, rest) {
        case (1, 0): return "1 minuto"
        case (_, 0): return "\(minutes) minutos"
        default: return "\(minutes) min \(rest) s"
        }
    }
}
