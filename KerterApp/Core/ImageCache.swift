import SwiftUI
import CryptoKit
import ImageIO
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

/// Semáforo para las cargas de imagen: limita cuántas corren a la vez, atiende
/// primero lo último que se pidió (LIFO) y suelta al instante lo cancelado.
///
/// Al hacer scroll rápido por una cuadrícula se piden decenas de imágenes de
/// celdas que salen de pantalla enseguida. Con una cola FIFO, lo visible
/// esperaría detrás de todo eso; con LIFO lo último pedido (lo que hay ahora
/// en pantalla) va primero, y lo que ya pasó se cancela sin llegar a
/// descargarse ni decodificarse.
private actor LoadGate {
    private let limit: Int
    private var active = 0
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextID: UInt64 = 0

    init(limit: Int) { self.limit = limit }

    /// Espera un hueco. Lanza `CancellationError` si la tarea se cancela
    /// mientras espera (y entonces no ocupa hueco: no hay que llamar a `release`).
    func acquire() async throws {
        try Task.checkCancellation()
        if active < limit {
            active += 1
            return
        }
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters.append((id, $0)) }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release() {
        // El hueco pasa directo al último en llegar; si no hay nadie, se libera.
        if let next = waiters.popLast() {
            next.continuation.resume()
        } else {
            active -= 1
        }
    }

    private func cancel(_ id: UInt64) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).continuation.resume(throwing: CancellationError())
    }
}

/// Caché de imágenes en disco + memoria. Los escudos/jugadores no cambian,
/// así que se descargan una vez y se reutilizan (ahorra datos y carga al instante).
///
/// Todo lo que toca es thread-safe (NSCache, FileManager, URLSession, el lock),
/// así que no es un actor: las cargas corren en el pool concurrente, con dos
/// límites — pocas descargas a la vez y tantas decodificaciones como núcleos
/// razonables — para no saturar ni la red ni la CPU al hacer scroll.
final class ImageDiskCache: @unchecked Sendable {
    static let shared = ImageDiskCache()

    /// Bitmap ya decodificado + si se decodificó a resolución completa
    /// (entonces no hay versión más grande que pedir).
    private final class Entry {
        let image: PlatformImage
        let pixelSize: CGSize
        let isFullResolution: Bool

        init(image: PlatformImage, pixelSize: CGSize, isFullResolution: Bool) {
            self.image = image
            self.pixelSize = pixelSize
            self.isFullResolution = isFullResolution
        }

        /// ¿Se ve nítida al pintarla en `target` píxeles con ese modo?
        func covers(_ target: CGSize, _ mode: ContentMode) -> Bool {
            if isFullResolution { return true }
            guard pixelSize.width > 0, pixelSize.height > 0 else { return false }
            return ImageDiskCache.scale(from: pixelSize, to: target, mode) <= 1.05
        }
    }

    /// Una carga en curso, compartida por todas las vistas que piden la misma
    /// imagen al mismo tamaño (p. ej. el logo de la competición repetido en
    /// cada tarjeta de la cuadrícula): se descarga y decodifica una sola vez.
    /// Se cancela cuando la última vista que la esperaba desaparece.
    private final class Flight {
        var task: Task<Entry?, Never>?
        var waiters = 0
    }

    private let dir: URL
    /// Una entrada por URL (la versión más grande decodificada), con coste en
    /// bytes del bitmap: el límite es de memoria real, no de número de fotos.
    private let mem: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()

    private let flightsLock = NSLock()
    private var flights: [String: Flight] = [:]

    /// Descargas: pocas a la vez para que las visibles terminen rápido en vez
    /// de repartirse el ancho de banda con todo lo demás.
    private let downloadGate = LoadGate(limit: 4)
    /// Lectura de disco + decodificación: trabajo de CPU, acotado a la mitad
    /// de los núcleos (2…4) para dejar libre el resto al scroll y al video.
    private let decodeGate = LoadGate(limit: max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2)))

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("KerterImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Nombre de archivo estable (SHA-256 del URL) — sobrevive reinicios.
    /// Solo se calcula al ir a disco, nunca en el `body` de una vista.
    private func fileKey(_ url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func memKey(_ url: URL) -> NSString { url.absoluteString as NSString }

    /// Cualquier versión ya decodificada, sin esperas (para pintar al instante
    /// mientras llega una más nítida). `nil` si aún no está.
    func inMemory(_ url: URL) -> PlatformImage? {
        mem.object(forKey: memKey(url))?.image
    }

    /// Solo si la versión en memoria es lo bastante grande para `target`.
    func inMemory(_ url: URL, covering target: CGSize, mode: ContentMode) -> PlatformImage? {
        guard let entry = mem.object(forKey: memKey(url)), entry.covers(target, mode) else { return nil }
        return entry.image
    }

    /// `target` es el tamaño en píxeles en que se va a pintar (puntos × escala
    /// de pantalla): se decodifica justo a esa medida, ni más ni menos.
    /// Devuelve `nil` si falla o si la tarea se cancela (la vista salió de pantalla).
    func image(for url: URL, target: CGSize, mode: ContentMode) async -> PlatformImage? {
        if let hit = inMemory(url, covering: target, mode: mode) { return hit }

        let key = "\(url.absoluteString)|\(Int(target.width))x\(Int(target.height))|\(mode == .fit ? "fit" : "fill")"
        let flight = join(key) { [self] in await load(url, target: target, mode: mode) }
        let entry = await withTaskCancellationHandler {
            await flight.task?.value
        } onCancel: {
            leave(key, flight)
        }
        if !Task.isCancelled { leave(key, flight) }
        return entry?.image
    }

    private func join(_ key: String, start: @escaping @Sendable () async -> Entry?) -> Flight {
        flightsLock.lock()
        defer { flightsLock.unlock() }
        if let existing = flights[key] {
            existing.waiters += 1
            return existing
        }
        let flight = Flight()
        flight.waiters = 1
        flights[key] = flight
        flight.task = Task { [weak self, weak flight] in
            let entry = await start()
            if let self, let flight { self.finish(key, flight) }
            return entry
        }
        return flight
    }

    /// Una vista deja de esperar. Si era la última, se cancela la carga
    /// (y con ella la descarga o su hueco en la cola).
    private func leave(_ key: String, _ flight: Flight) {
        flightsLock.lock()
        defer { flightsLock.unlock() }
        guard flight.waiters > 0 else { return }
        flight.waiters -= 1
        if flight.waiters == 0 {
            flight.task?.cancel()
            if flights[key] === flight { flights[key] = nil }
        }
    }

    private func finish(_ key: String, _ flight: Flight) {
        flightsLock.lock()
        defer { flightsLock.unlock() }
        if flights[key] === flight { flights[key] = nil }
    }

    private func load(_ url: URL, target: CGSize, mode: ContentMode) async -> Entry? {
        if let hit = mem.object(forKey: memKey(url)), hit.covers(target, mode) { return hit }
        let file = dir.appendingPathComponent(fileKey(url))

        // 1) Ya en disco: leer + decodificar dentro del cupo de CPU.
        if FileManager.default.fileExists(atPath: file.path) {
            guard (try? await decodeGate.acquire()) != nil else { return nil }
            let entry = (try? Data(contentsOf: file)).flatMap { Self.decode($0, target: target, mode: mode) }
            await decodeGate.release()
            if let entry {
                store(entry, for: url)
                return entry
            }
        }

        // 2) De la red. Una pausa corta antes: en un scroll rápido la celda
        //    suele desaparecer antes, y así ni siquiera se abre la conexión.
        guard (try? await Task.sleep(for: .milliseconds(80))) != nil else { return nil }
        // Reintenta ante fallos de red o 429/5xx; un 404 no tiene arreglo.
        var fetched: (Data, URLResponse)?
        for attempt in 0..<3 {
            if attempt > 0 { guard (try? await Task.sleep(for: .milliseconds(700 * attempt))) != nil else { return nil } }
            guard (try? await downloadGate.acquire()) != nil else { return nil }
            let result = try? await URLSession.shared.data(from: url)
            await downloadGate.release()
            guard let result else { continue }
            let code = (result.1 as? HTTPURLResponse)?.statusCode ?? 200
            if (200..<300).contains(code) { fetched = result; break }
            if code != 429 && code < 500 { return nil }
        }

        guard let (data, _) = fetched else { return nil }
        // Se guarda aunque ya nadie la espere: si se vuelve a ella, sale de disco.
        try? data.write(to: file, options: .atomic)

        guard (try? await decodeGate.acquire()) != nil else { return nil }
        let entry = Self.decode(data, target: target, mode: mode)
        await decodeGate.release()
        if let entry { store(entry, for: url) }
        return entry
    }

    /// No pisa una versión más grande con una más pequeña (dos vistas del
    /// mismo escudo a distinto tamaño decodificando a la vez).
    private func store(_ entry: Entry, for url: URL) {
        let key = memKey(url)
        if let current = mem.object(forKey: key),
           current.pixelSize.width * current.pixelSize.height >= entry.pixelSize.width * entry.pixelSize.height {
            return
        }
        let cost = Int(entry.pixelSize.width * entry.pixelSize.height * 4)
        mem.setObject(entry, forKey: key, cost: max(cost, 1))
    }

    /// Factor por el que hay que escalar una imagen de `source` px para
    /// pintarla en `target` px: `.fit` cabe entera, `.fill` cubre el marco.
    fileprivate static func scale(from source: CGSize, to target: CGSize, _ mode: ContentMode) -> CGFloat {
        let sx = target.width / source.width, sy = target.height / source.height
        return mode == .fit ? min(sx, sy) : max(sx, sy)
    }

    /// Decodifica ya (no al dibujar) y reduce la imagen al tamaño en que se va
    /// a mostrar: mucho más barato de renderizar y de memoria.
    private static func decode(_ data: Data, target: CGSize, mode: ContentMode) -> Entry? {
        guard let src = CGImageSourceCreateWithData(data as CFData,
                                                    [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return fallback(data)
        }

        // Medidas originales (girando si la orientación EXIF las intercambia)
        // para calcular el lado mayor exacto que necesita el marco.
        var maxSide = max(target.width, target.height)
        var isFull = false
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
           let h = props[kCGImagePropertyPixelHeight] as? CGFloat, w > 0, h > 0 {
            let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
            let source = orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
            let factor = scale(from: source, to: target, mode)
            isFull = factor >= 1
            maxSide = (max(source.width, source.height) * min(factor, 1)).rounded(.up)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxSide, 1)
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            return fallback(data)
        }
        let size = CGSize(width: cg.width, height: cg.height)
        #if os(macOS)
        let image = NSImage(cgImage: cg, size: size)
        #else
        let image = UIImage(cgImage: cg)
        #endif
        return Entry(image: image, pixelSize: size, isFullResolution: isFull)
    }

    /// Formatos que ImageIO no entiende (p. ej. SVG): los pinta el sistema.
    /// Es vectorial, así que cuenta como "resolución completa".
    private static func fallback(_ data: Data) -> Entry? {
        guard let image = PlatformImage(data: data) else { return nil }
        return Entry(image: image, pixelSize: .zero, isFullResolution: true)
    }
}

/// Imagen remota con caché en disco. Reemplaza a `AsyncImage` para logos/jugadores.
///
/// Se decodifica al tamaño real de la vista × escala de pantalla (medido con
/// `onGeometryChange`): un escudo de 20 pt pide ~40 px y la portada de una
/// ventana grande pide lo que ocupe, sin números fijos en cada llamada.
struct CachedImage: View {
    let url: URL?
    var contentMode: ContentMode = .fit
    var placeholder: Color = Color.white.opacity(0.06)

    @Environment(\.displayScale) private var displayScale
    @State private var pointSize: CGSize = .zero
    @State private var loaded: (url: URL, image: PlatformImage)?

    private struct Request: Equatable {
        let url: URL?
        let pixels: CGSize
    }

    /// Tamaño en píxeles redondeado hacia arriba a escalones: al redimensionar
    /// la ventana o animar no se redecodifica en cada punto.
    private var targetPixels: CGSize {
        func bucket(_ v: CGFloat) -> CGFloat {
            let step: CGFloat = v <= 512 ? 32 : 128
            return (v / step).rounded(.up) * step
        }
        return CGSize(width: bucket(pointSize.width * displayScale),
                      height: bucket(pointSize.height * displayScale))
    }

    /// Lo decodificado para este URL, o lo que ya haya en memoria (aunque sea
    /// más pequeño) para pintar al instante, sin parpadeo, mientras llega.
    private var current: PlatformImage? {
        guard let url else { return nil }
        if let loaded, loaded.url == url { return loaded.image }
        return ImageDiskCache.shared.inMemory(url)
    }

    var body: some View {
        Group {
            if let image = current {
                #if os(macOS)
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
                #else
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                #endif
            } else {
                placeholder
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { pointSize = $0 }
        // `.task` se cancela cuando la celda sale de pantalla (en contenedores
        // Lazy): eso libera su turno en la cola o corta su descarga.
        .task(id: Request(url: url, pixels: targetPixels)) {
            guard let url else { loaded = nil; return }
            let target = targetPixels
            guard target.width > 0, target.height > 0 else { return }
            let cache = ImageDiskCache.shared
            if let ready = cache.inMemory(url, covering: target, mode: contentMode) {
                loaded = (url, ready)
                return
            }
            if loaded?.url != url { loaded = nil }
            if let image = await cache.image(for: url, target: target, mode: contentMode) {
                loaded = (url, image)
            }
        }
    }
}
