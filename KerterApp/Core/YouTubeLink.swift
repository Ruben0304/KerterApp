import Foundation

extension YouTubeHighlightsService.Highlight {
    /// La app nunca reproduce el resumen dentro de sí misma — solo comprueba
    /// que ya está publicado en el canal de la fuente (`highlight(for:...)`)
    /// y enlaza directo al video. Un enlace `https://www.youtube.com/watch`
    /// abre la app de YouTube si está instalada (universal link) o, si no,
    /// el navegador — sin pantalla propia de por medio.
    var watchURL: URL {
        URL(string: "https://www.youtube.com/watch?v=\(id)")!
    }
}
