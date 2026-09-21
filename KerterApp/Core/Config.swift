import Foundation

/// Configuración central de la app.
///
/// Los valores del backend se descubrieron analizando el bundle React Native
/// de Kerter+ (Hermes). Si cambian, se ajustan aquí en un solo lugar.
enum AppConfig {
    /// Backend REST de Kerter+ (auth, canales, pagos). El API vive bajo /api.
    static let apiBaseURL = URL(string: "https://kerterplus.duckdns.org/api")!

    /// CDN de imágenes/media (logos, posters).
    static let mediaBaseURL = URL(string: "https://cdn.socy.cloud")!

    /// Stream HLS público de Apple para el modo demo (que el player funcione sin cuenta).
    static let demoStreamURL = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8")!
}
