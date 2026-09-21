import Foundation
import CryptoKit
import os

/// Graba un directo HLS en disco y se lo sirve a AVPlayer desde el propio dispositivo (IP de la red local, para AirPlay).
///
/// Por qué: los servidores de los canales solo guardan 14–30 s de directo y
/// AVPlayer baja los fragmentos de uno en uno por una sola conexión. Con una
/// conexión que va de buena a muy mala, eso se traduce en cortes y en quedarse
/// fuera de la ventana del servidor (el video se rompe). Aquí:
/// - el grabador baja cada fragmento en cuanto aparece, por varias conexiones
///   (`SegmentFetcher`), y lo guarda en disco, donde no caduca: el margen
///   puede crecer más allá de lo que guarda el servidor, se puede pausar para
///   juntar colchón y rebobinar;
/// - la calidad la decide el grabador, fragmento a fragmento, mirando sobre
///   todo el margen grabado y si se está quedando atrás (la velocidad medida es
///   ruido con esta conexión); baja al momento y sube de uno en uno;
/// - AVPlayer solo ve una playlist local con lo grabado: nunca toca internet.
///
/// Todo su estado vive en `queue` (de ahí `@unchecked Sendable`).
final class LiveProxy: @unchecked Sendable {
    struct Status: Equatable {
        /// Segundos grabados por delante de lo que se está viendo.
        var bufferAhead: Double
        var level: Int
        var height: Int
        /// Velocidad estimada de la conexión (bits/s), prudente.
        var throughput: Double?
        /// Cuánto va el grabador por detrás de lo que publica el servidor.
        var behindLive: Double
        /// Fragmentos que el servidor borró antes de poder bajarlos.
        var lostSegments: Int
        /// Conexiones recibiendo datos ahora mismo.
        var transferring: Int
        /// El canal no emite: su servidor publica fragmentos vacíos (fallo en
        /// su origen, no de la conexión).
        var sourceDown: Bool
    }

    fileprivate struct Recorded: Codable {
        let localSequence: Int
        let duration: Double
        let level: Int
        let discontinuity: Bool
        let date: Date
    }

    /// Lo grabado de un canal y dónde ibas: se guarda al cerrar el reproductor
    /// (y cada 10 s mientras se ve, por si la app se cierra de golpe) para
    /// ofrecer "Continuar viendo" al volver.
    struct SavedSession: Codable {
        let source: URL
        let savedAt: Date
        let playhead: Date?
        fileprivate let timelineStart: Date
        fileprivate let timelineEnd: Date
        fileprivate let targetDuration: Double
        fileprivate let independentSegments: Bool
        fileprivate let firstLocalSequence: Int
        fileprivate let evictedDiscontinuities: Int
        fileprivate let segments: [Recorded]

        /// Lo visto antes de cerrar (grabado por detrás de donde ibas).
        var watched: Double { playhead.map { $0.timeIntervalSince(timelineStart) } ?? 0 }
        /// Lo grabado por delante de donde ibas.
        var ahead: Double { playhead.map { max(0, timelineEnd.timeIntervalSince($0)) } ?? 0 }
    }

    /// Lo guardado caduca a las 3 h (el partido ya acabó) y solo se guardan
    /// los últimos canales.
    static let savedLifetime: TimeInterval = 3 * 3600
    private static let maxSavedSessions = 3

    private struct Finished {
        let data: Data
        let level: Int
        let duration: Double
        let discontinuity: Bool
    }

    private struct EWMA {
        let halfLife: Double
        private var estimate = 0.0
        private var weight = 0.0
        init(halfLife: Double) { self.halfLife = halfLife }
        mutating func add(_ value: Double, weight w: Double) {
            let alpha = pow(0.5, w / halfLife)
            estimate = value * (1 - alpha) + alpha * estimate
            weight += w
        }
        var value: Double? { weight >= 1 ? estimate / (1 - pow(0.5, weight / halfLife)) : nil }
    }

    /// Calidades disponibles, de menor a mayor bitrate. Fijas tras arrancar.
    private(set) var variants: [HLS.Variant] = []
    private(set) var localURL: URL?

    private let queue = DispatchQueue(label: "kerter.live-proxy")
    private let source: URL
    private let fetcher: SegmentFetcher
    private var server: LocalHTTPServer?
    private let directory: URL
    private var statusHandler: ((Status) -> Void)?

    // Estado del grabador (todo en `queue`).
    private var level = 0
    private var manualLevel: Int?
    private var abrEnabled = true
    private var alignmentCheckFrom: Int?
    private var playlists: [Int: (playlist: HLS.MediaPlaylist, at: Date)] = [:]
    private var targetDuration = 3.0
    private var independentSegments = false
    private var nextSequence: Int?
    private var appendCursor = 0
    private var jobs: [Int: SegmentFetcher.Job] = [:]
    private var finished: [Int: Finished] = [:]
    private var skipped: Set<Int> = []
    private var recorded: [Recorded] = []
    private var firstLocalSequence = 0
    private var evictedDiscontinuities = 0
    private var gapPending = false
    private var timelineStart = Date()
    private var timelineEnd = Date()
    private var sizes: [Int: [Int]] = [:]
    private var fastRate = EWMA(halfLife: 3)
    private var slowRate = EWMA(halfLife: 10)
    private var silentFor: TimeInterval = 0
    private var playhead: Date?
    private var lagHistory: [(at: Date, lag: Int)] = []
    private var caughtUp = false
    private let startedAt = Date()
    private var lastDown = Date.distantPast
    private var lastUp = Date.distantPast
    private var lost = 0
    private var pollInFlight = false
    private var pollID = 0
    private var pollAgain = false
    private var pollGeneration = 0
    private var pollFailures = 0
    private var lastPlaylistSuccess = Date()
    private var upstreamEnded = false
    /// Desde cuándo el servidor publica fragmentos vacíos (duración ~0).
    private var brokenSince: Date?
    private var timer: DispatchSourceTimer?
    private var ticks = 0
    private var stopped = false
    private var readyHandler: ((Bool) -> Void)?
    /// Retomando lo guardado: ya se está viendo, la red se reintenta sin rendirse.
    private var resuming = false
    /// Cuánto se guarda por detrás de lo que se ve (para rebobinar).
    private var keepBehind: TimeInterval = 2 * 3600

    private static let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("KerterLive", isDirectory: true)

    /// Una carpeta por canal: lo guardado de cada uno se retoma por separado.
    private static func directory(for source: URL) -> URL {
        let digest = SHA256.hash(data: Data(source.absoluteString.utf8))
        let key = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(key, isDirectory: true)
    }

    private var manifestURL: URL { directory.appendingPathComponent("session.json") }

    private func file(_ localSequence: Int) -> URL {
        directory.appendingPathComponent("\(localSequence).ts")
    }
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private init(source: URL) {
        self.source = source
        directory = Self.directory(for: source)
        fetcher = SegmentFetcher(queue: queue)
    }

    // MARK: - API pública

    /// Arranca el grabador para `source` y espera a tener los primeros
    /// fragmentos. Devuelve nil si el stream no se puede grabar (VOD, cifrado,
    /// fMP4…) o no arranca a tiempo: entonces se reproduce directo del servidor.
    /// `onStatus` recibe el estado cada medio segundo (en el hilo principal)
    /// desde el arranque: así se puede avisar si el canal no emite.
    static func start(source: URL, onStatus: @escaping (Status) -> Void) async -> LiveProxy? {
        let proxy = LiveProxy(source: source)
        proxy.statusHandler = onStatus
        // Si quien espera se cancela (se cerró el reproductor), el grabador se
        // para: si no, con un canal caído seguiría esperando para siempre.
        let ok = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                proxy.queue.async { proxy.boot { continuation.resume(returning: $0) } }
            }
        } onCancel: {
            proxy.stop()
        }
        guard ok, let port = proxy.server?.port else {
            proxy.stop()
            return nil
        }
        proxy.localURL = URL(string: "http://\(LocalHTTPServer.lanAddress() ?? "127.0.0.1"):\(port)/live.m3u8")
        return proxy
    }

    /// Lo guardado de ese canal, si no ha caducado.
    static func savedSession(for source: URL) -> SavedSession? {
        let url = directory(for: source).appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(SavedSession.self, from: data),
              saved.source == source,
              Date().timeIntervalSince(saved.savedAt) < savedLifetime,
              saved.playhead != nil, !saved.segments.isEmpty else { return nil }
        return saved
    }

    /// Retoma lo guardado: está listo al momento (lo grabado se sirve ya, sin
    /// esperar a la red) y en paralelo vuelve a grabar el directo, que queda
    /// a continuación tras un salto (lo que pasó con el reproductor cerrado
    /// no se grabó).
    static func resume(_ saved: SavedSession, onStatus: @escaping (Status) -> Void) async -> LiveProxy? {
        let proxy = LiveProxy(source: saved.source)
        proxy.statusHandler = onStatus
        proxy.restore(saved)
        let ok = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                proxy.queue.async { proxy.bootResuming { continuation.resume(returning: $0) } }
            }
        } onCancel: {
            proxy.stop(saving: true)
        }
        guard ok, let port = proxy.server?.port else {
            proxy.stop(saving: true)
            return nil
        }
        proxy.localURL = URL(string: "http://\(LocalHTTPServer.lanAddress() ?? "127.0.0.1"):\(port)/live.m3u8")
        return proxy
    }

    /// Fecha (de la playlist local) de lo que se está viendo.
    func reportPlayhead(_ date: Date?) {
        queue.async { self.playhead = date ?? self.playhead }
    }

    /// nil = automática.
    func setManualLevel(_ level: Int?) {
        queue.async {
            self.manualLevel = level
            if let level, level != self.level { self.switchLevel(to: level) }
        }
    }

    /// Cambio de red: las conexiones viejas pueden estar muertas sin saberlo.
    func networkChanged(online: Bool) {
        guard online else { return }
        queue.async {
            ProxyLog.log("red de vuelta/cambiada → conexiones nuevas")
            self.fetcher.resetAll()
            self.pollNow()
        }
    }

    /// El reproductor lleva rato atascado: rehacer conexiones y releer.
    func kick() {
        queue.async {
            ProxyLog.log("reproductor atascado → conexiones nuevas")
            self.fetcher.resetAll()
            self.pollNow()
        }
    }

    /// Deja de descargar. Con `saving`, lo grabado y dónde ibas se quedan en
    /// disco para "Continuar viendo"; si no, se borra.
    func stop(saving: Bool = false) {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.timer?.cancel()
            self.fetcher.invalidate()
            self.server?.stop()
            if saving, self.playhead != nil, !self.recorded.isEmpty {
                self.saveSession()
                ProxyLog.log("guardado para continuar: \(Int(self.bufferAhead)) s por delante")
            } else {
                try? FileManager.default.removeItem(at: self.directory)
            }
            if let ready = self.readyHandler {
                self.readyHandler = nil
                ready(false)
            }
        }
    }

    /// Solo para pruebas: la red "desaparece" durante `seconds`.
    func simulateOutage(_ seconds: TimeInterval) {
        queue.async {
            ProxyLog.log("SIMULACIÓN: corte de red de \(Int(seconds)) s")
            self.fetcher.simulateOutage(seconds)
        }
    }

    #if DEBUG
    func debugConnections(_ handler: @escaping ([Int]) -> Void) {
        queue.async { handler(self.fetcher.recentLocalPorts) }
    }
    #endif

    // MARK: - Arranque

    private func boot(completion: @escaping (Bool) -> Void) {
        guard !stopped else { return completion(false) }
        // Arranque en vivo: lo guardado de este canal se descarta.
        try? FileManager.default.removeItem(at: directory)
        Self.cleanUpSavedSessions(keeping: directory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return completion(false)
        }
        readyHandler = completion
        armBootDeadline()
        loadSource(attempt: 1)
    }

    private func restore(_ saved: SavedSession) {
        recorded = saved.segments
        firstLocalSequence = saved.firstLocalSequence
        evictedDiscontinuities = saved.evictedDiscontinuities
        timelineStart = saved.timelineStart
        timelineEnd = saved.timelineEnd
        targetDuration = saved.targetDuration
        independentSegments = saved.independentSegments
        playhead = saved.playhead
        // Lo que se grabe ahora va tras un salto.
        gapPending = true
    }

    private func bootResuming(completion: @escaping (Bool) -> Void) {
        guard !stopped else { return completion(false) }
        Self.cleanUpSavedSessions(keeping: directory)
        resuming = true
        startServer { [weak self] ok in
            guard let self, !self.stopped else { return completion(false) }
            guard ok else { return completion(false) }
            ProxyLog.log("continuar viendo: \(self.recorded.count) fragmentos guardados · \(Int(self.bufferAhead)) s por delante")
            // Lo guardado se puede ver ya; el directo se retoma en paralelo.
            completion(true)
            self.startTimer()
            self.loadSource(attempt: 1)
        }
    }

    /// Borra lo guardado caducado, sin sesión o de sobra (se quedan los más recientes).
    private static func cleanUpSavedSessions(keeping current: URL) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        var sessions: [(dir: URL, savedAt: Date)] = []
        for dir in dirs where dir.standardizedFileURL != current.standardizedFileURL {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
                  let saved = try? JSONDecoder().decode(SavedSession.self, from: data),
                  Date().timeIntervalSince(saved.savedAt) < savedLifetime else {
                try? fm.removeItem(at: dir)
                continue
            }
            sessions.append((dir, saved.savedAt))
        }
        for old in sessions.sorted(by: { $0.savedAt > $1.savedAt }).dropFirst(maxSavedSessions - 1) {
            try? fm.removeItem(at: old.dir)
        }
    }

    private func saveSession() {
        let saved = SavedSession(source: source, savedAt: Date(), playhead: playhead,
                                 timelineStart: timelineStart, timelineEnd: timelineEnd,
                                 targetDuration: targetDuration, independentSegments: independentSegments,
                                 firstLocalSequence: firstLocalSequence,
                                 evictedDiscontinuities: evictedDiscontinuities, segments: recorded)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    /// Plazo de arranque: 25 s. Si el canal no emite (fragmentos vacíos), se
    /// sigue esperando a que vuelva en vez de rendirse.
    private func armBootDeadline() {
        queue.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, self.readyHandler != nil else { return }
            if self.sourceDown { return self.armBootDeadline() }
            let ready = self.readyHandler
            self.readyHandler = nil
            ProxyLog.log("arranque: plazo agotado con \(self.recorded.count) fragmentos")
            ready?(!self.recorded.isEmpty)
        }
    }

    private var sourceDown: Bool {
        brokenSince.map { Date().timeIntervalSince($0) > 2 } ?? false
    }

    private func finishBoot(_ ok: Bool, _ reason: String? = nil) {
        if let reason { ProxyLog.log("no se graba: \(reason)") }
        guard let ready = readyHandler else { return }
        if !ok {
            readyHandler = nil
            ready(false)
        }
    }

    private func loadSource(attempt: Int) {
        fetcher.fetchText(source, timeout: 8) { [weak self] result in
            guard let self, !self.stopped else { return }
            switch result {
            case .failure:
                guard attempt < 3 || self.resuming else { return self.finishBoot(false, "no carga la playlist") }
                self.queue.asyncAfter(deadline: .now() + (self.resuming ? 2 : 0.5)) { self.loadSource(attempt: attempt + 1) }
            case .success(let (text, url)):
                switch HLS.parse(text, url: url) {
                case .master(let variants, let unsupported)?:
                    if let unsupported { return self.finishBoot(false, unsupported) }
                    guard !variants.isEmpty else { return self.finishBoot(false, "playlist sin variantes") }
                    self.variants = variants
                    // Se arranca en la segunda más baja: la ventana del servidor
                    // entra rápido y luego se sube si la conexión lo permite.
                    self.level = variants.count >= 3 ? 1 : 0
                    self.loadFirstMedia(attempt: 1)
                case .media(let playlist)?:
                    self.variants = [HLS.Variant(bandwidth: 0, width: 0, height: 0, url: playlist.url)]
                    self.level = 0
                    self.beginRecording(playlist)
                case nil:
                    self.finishBoot(false, "playlist ilegible")
                }
            }
        }
    }

    private func loadFirstMedia(attempt: Int) {
        let requested = level
        fetcher.fetchText(variants[requested].url, timeout: 8) { [weak self] result in
            guard let self, !self.stopped else { return }
            guard case .success(let (text, url)) = result, case .media(let playlist)? = HLS.parse(text, url: url) else {
                guard attempt < 3 || self.resuming else { return self.finishBoot(false, "no carga la variante") }
                self.queue.asyncAfter(deadline: .now() + (self.resuming ? 2 : 0.5)) { self.loadFirstMedia(attempt: attempt + 1) }
                return
            }
            self.beginRecording(playlist)
        }
    }

    private func beginRecording(_ playlist: HLS.MediaPlaylist) {
        if let unsupported = playlist.unsupported { return finishBoot(false, unsupported) }
        guard !playlist.isEnded else { return finishBoot(false, "no es un directo") }
        guard !playlist.segments.isEmpty else { return finishBoot(false, "playlist vacía") }
        independentSegments = playlist.independentSegments

        startServer { [weak self] ok in
            guard let self, !self.stopped else { return }
            guard ok else { return self.finishBoot(false, "no abre el servidor local") }
            ProxyLog.log("grabando \(self.source.absoluteString) · \(self.variants.count) calidades · "
                         + "ventana \(Int(Double(playlist.segments.count) * playlist.targetDuration)) s · puerto \(self.server?.port ?? 0)")
            if self.timer == nil { self.startTimer() }
            self.ingest(playlist, level: self.level)
            self.schedulePoll(after: self.pollInterval)
        }
    }

    private func startServer(_ completion: @escaping (Bool) -> Void) {
        if server != nil { return completion(true) }
        let server = LocalHTTPServer(queue: queue) { [weak self] path in self?.handle(path) }
        self.server = server
        server.start(ready: completion)
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    // MARK: - Playlist del servidor

    private var pollInterval: TimeInterval { min(2, max(0.5, targetDuration / 2)) }

    private func schedulePoll(after delay: TimeInterval) {
        pollGeneration += 1
        let generation = pollGeneration
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.pollGeneration else { return }
            self.poll()
        }
    }

    private func pollNow() {
        if pollInFlight { pollAgain = true } else { poll() }
    }

    private func poll() {
        guard !stopped, !pollInFlight else { return }
        pollInFlight = true
        pollID += 1
        let id = pollID
        let requested = level
        fetcher.fetchText(variants[requested].url, timeout: 6) { [weak self] result in
            // Una respuesta de una consulta ya abandonada no cuenta.
            guard let self, !self.stopped, id == self.pollID else { return }
            self.pollInFlight = false
            if case .success(let (text, url)) = result, case .media(let playlist)? = HLS.parse(text, url: url) {
                self.pollFailures = 0
                self.ingest(playlist, level: requested)
            } else {
                self.pollFailures += 1
                if self.pollFailures == 2 { self.fetcher.renewPlaylistConnection() }
            }
            if self.pollAgain {
                self.pollAgain = false
                self.poll()
            } else if !self.upstreamEnded {
                self.schedulePoll(after: self.pollFailures > 0 ? min(2, 0.5 * Double(self.pollFailures)) : self.pollInterval)
            }
        }
    }

    private func ingest(_ playlist: HLS.MediaPlaylist, level fetchedLevel: Int) {
        lastPlaylistSuccess = Date()
        playlists[fetchedLevel] = (playlist, Date())
        guard fetchedLevel == level else { return }
        targetDuration = playlist.targetDuration

        // Fragmentos de duración ~0 sin imagen: el codificador del canal falla.
        let empty = playlist.segments.filter { $0.duration < 0.1 }.count
        if !playlist.segments.isEmpty, empty * 2 >= playlist.segments.count {
            if brokenSince == nil { ProxyLog.log("el canal publica fragmentos vacíos: su señal de origen está caída") }
            brokenSince = brokenSince ?? Date()
        } else if brokenSince != nil {
            ProxyLog.log("el canal vuelve a emitir")
            brokenSince = nil
        }

        if let previous = alignmentCheckFrom {
            alignmentCheckFrom = nil
            if alignment(of: playlist, level: fetchedLevel) == false {
                ProxyLog.log("las calidades no van sincronizadas → calidad fija")
                abrEnabled = false
                manualLevel = nil
                level = previous
                pollNow()
                return
            }
        }

        if nextSequence == nil {
            // Desde lo más antiguo que guarda el servidor (más margen de
            // entrada), menos el primero, que puede desaparecer mientras baja.
            let first = playlist.segments.count >= 4 ? playlist.firstSequence + 1 : playlist.firstSequence
            nextSequence = first
            appendCursor = first
        }
        guard var next = nextSequence else { return }

        // El stream se reinició (la numeración vuelve atrás): se empieza de nuevo.
        if playlist.lastSequence + 3 < appendCursor {
            ProxyLog.log("el servidor reinició la numeración → se continúa desde su inicio")
            jobs.values.forEach(fetcher.cancel)
            jobs.removeAll()
            finished.removeAll()
            skipped.removeAll()
            next = playlist.firstSequence
            appendCursor = next
            gapPending = true
        }
        // Lo que el servidor ya borró sin que llegáramos a pedirlo.
        if next < playlist.firstSequence {
            let missing = (next..<playlist.firstSequence).filter { jobs[$0] == nil && finished[$0] == nil }
            skipped.formUnion(missing)
            // Con el canal caído son fragmentos vacíos: no se pierde nada.
            if !missing.isEmpty, brokenSince == nil {
                lost += missing.count
                ProxyLog.log("perdidos \(missing.count) fragmentos (el servidor ya los borró)")
            }
            next = playlist.firstSequence
        }
        nextSequence = next
        upstreamEnded = playlist.isEnded
        appendInOrder()
        schedule()
    }

    /// ¿Van las calidades sincronizadas (mismos números de fragmento con la
    /// misma duración)? Se compara con la playlist más reciente de otra
    /// calidad; nil si no hay fragmentos en común con los que comparar (solo
    /// se desactiva el cambio de calidad con pruebas de que no cuadran).
    private func alignment(of new: HLS.MediaPlaylist, level: Int) -> Bool? {
        guard let old = playlists.filter({ $0.key != level }).max(by: { $0.value.at < $1.value.at })?.value.playlist
        else { return nil }
        let lower = max(new.firstSequence, old.firstSequence)
        let upper = min(new.lastSequence, old.lastSequence)
        guard lower <= upper else { return nil }
        return (lower...upper).allSatisfy { sequence in
            guard let a = new.segment(sequence), let b = old.segment(sequence) else { return false }
            return abs(a.duration - b.duration) < 0.1
        }
    }

    // MARK: - Descargas

    private func schedule() {
        guard !stopped else { return }
        var skippedEmpty = false
        defer { if skippedEmpty { appendInOrder() } }
        while fetcher.idleLaneCount > 0, jobs.count < fetcher.laneCount, let next = nextSequence {
            let wanted = chooseLevel()
            if wanted != level { switchLevel(to: wanted) }
            guard alignmentCheckFrom == nil,
                  let (playlist, fetchedAt) = playlists[level],
                  Date().timeIntervalSince(fetchedAt) < max(6, 3 * targetDuration),
                  let segment = playlist.segment(next) else { break }

            // Duración ~0: sin imagen que mostrar (canal con la señal caída).
            if segment.duration < 0.05 {
                skipped.insert(next)
                nextSequence = next + 1
                skippedEmpty = true
                continue
            }

            let chosen = level
            // Si no hay nada más pendiente, el fragmento se parte entre las
            // conexiones libres; si hay varios, va uno por conexión.
            let alone = playlist.lastSequence == next && jobs.isEmpty
            let job = fetcher.fetch(sequence: next, url: segment.url,
                                    estimatedSize: estimatedSize(level: chosen, duration: segment.duration),
                                    allowSplit: alone) { [weak self] result in
                self?.jobFinished(next, level: chosen, segment: segment, result)
            }
            jobs[next] = job
            nextSequence = next + 1
        }
    }

    private func estimatedSize(level: Int, duration: Double) -> Int? {
        if let recent = sizes[level], !recent.isEmpty {
            return recent.sorted()[recent.count / 2]
        }
        let bandwidth = variants[level].bandwidth
        return bandwidth > 0 ? Int(bandwidth * duration / 8 * 0.8) : nil
    }

    private func jobFinished(_ sequence: Int, level: Int, segment: HLS.Segment,
                             _ result: Result<Data, SegmentFetcher.Failure>) {
        guard !stopped, jobs.removeValue(forKey: sequence) != nil else { return }
        switch result {
        case .success(let data):
            finished[sequence] = Finished(data: data, level: level, duration: segment.duration,
                                          discontinuity: segment.discontinuity)
            sizes[level, default: []].append(data.count)
            if sizes[level]!.count > 8 { sizes[level]!.removeFirst() }
        case .failure(.cancelled):
            return
        case .failure(let failure):
            ProxyLog.log("seg \(sequence) perdido: \(failure)")
            skipped.insert(sequence)
            lost += 1
        }
        appendInOrder()
        schedule()
    }

    // MARK: - Grabación

    private func appendInOrder() {
        while true {
            if let segment = finished.removeValue(forKey: appendCursor) {
                append(segment)
            } else if skipped.remove(appendCursor) != nil {
                gapPending = true
            } else {
                break
            }
            appendCursor += 1
        }
        evictOld()
        checkReady()
    }

    private func append(_ segment: Finished) {
        let local = firstLocalSequence + recorded.count
        do {
            try segment.data.write(to: file(local))
        } catch {
            ProxyLog.log("no se pudo guardar un fragmento: \(error.localizedDescription)")
            gapPending = true
            return
        }
        if recorded.isEmpty { timelineStart = timelineEnd }
        let discontinuity = !recorded.isEmpty
            && (gapPending || segment.discontinuity || recorded.last?.level != segment.level)
        recorded.append(Recorded(localSequence: local, duration: segment.duration, level: segment.level,
                                 discontinuity: discontinuity, date: timelineEnd))
        timelineEnd = timelineEnd.addingTimeInterval(segment.duration)
        gapPending = false
    }

    private func evictOld() {
        // Hasta que se reproduce algo no se borra nada.
        guard let playhead else { return }
        let limit = playhead.addingTimeInterval(-keepBehind)
        var removed = 0
        while recorded.count - removed > 1 {
            let first = recorded[removed]
            guard first.date.addingTimeInterval(first.duration) < limit else { break }
            try? FileManager.default.removeItem(at: file(first.localSequence))
            if first.discontinuity { evictedDiscontinuities += 1 }
            removed += 1
        }
        if removed > 0 {
            recorded.removeFirst(removed)
            firstLocalSequence += removed
        }
    }

    private func checkReady() {
        guard let ready = readyHandler else { return }
        // Tres fragmentos dan para arrancar sin atascarse; con la conexión
        // muy mala, se arranca con lo que haya a los 8 s.
        if recorded.count >= 3 || (!recorded.isEmpty && Date().timeIntervalSince(startedAt) > 8) {
            readyHandler = nil
            ready(true)
        }
    }

    private var bufferAhead: Double {
        guard !recorded.isEmpty else { return 0 }
        let from = playhead ?? timelineStart
        return max(0, timelineEnd.timeIntervalSince(from))
    }

    // MARK: - Calidad

    /// Fragmentos que el servidor ya publicó y aún no están grabados.
    private var lagSegments: Int {
        guard let playlist = playlists[level]?.playlist else { return 0 }
        return max(0, playlist.lastSequence + 1 - appendCursor)
    }

    private var throughput: Double? {
        guard let fast = fastRate.value, let slow = slowRate.value else { return nil }
        return min(fast, slow)
    }

    /// La playlist del servidor responde con normalidad (si no, "al día"
    /// puede ser mentira: simplemente no nos enteramos de lo nuevo).
    private var serverReachable: Bool {
        pollFailures == 0 && Date().timeIntervalSince(lastPlaylistSuccess) < max(4, 2 * targetDuration)
    }

    /// El grabador pierde terreno: más pendiente que hace unos segundos.
    private var fallingBehind: Bool {
        let lag = lagSegments
        guard lag >= 3 else { return false }
        let reference = Date().addingTimeInterval(-max(4, 2 * targetDuration))
        guard let old = lagHistory.last(where: { $0.at <= reference }) else { return false }
        return lag > old.lag
    }

    /// Calidad para el siguiente fragmento. Lo principal es no cortarse: el
    /// margen grabado manda y la velocidad solo pone techo.
    private func chooseLevel() -> Int {
        if let manualLevel { return manualLevel }
        let top = variants.count - 1
        guard top > 0, abrEnabled, caughtUp else { return level }

        let now = Date()
        let buffer = bufferAhead
        let slack = (nextSequence ?? 0) - (playlists[level]?.playlist.firstSequence ?? 0)

        // 1. Pánico: casi sin margen, o el próximo fragmento está a punto de
        //    desaparecer del servidor → la más ligera, ya.
        if buffer < 8 || (slack <= 1 && lagSegments >= 3) { return 0 }

        let estimate = throughput
        let sustainable = estimate.map { rate in variants.lastIndex { $0.bandwidth <= rate * 0.7 } ?? 0 }
        var next = level

        if fallingBehind, now.timeIntervalSince(lastDown) > targetDuration {
            // 2. El grabador se atrasa: al menos un escalón abajo.
            next = min(level - 1, sustainable ?? level - 1)
        } else if let rate = estimate, rate < variants[level].bandwidth, let sustainable {
            // 3. La conexión ya no da ni para la calidad actual.
            next = min(level, sustainable)
        } else if level < top, lagSegments <= 1, buffer >= 20, serverReachable,
                  now.timeIntervalSince(lastDown) >= 30, now.timeIntervalSince(lastUp) >= 15,
                  let rate = estimate, rate * 0.6 >= variants[level + 1].bandwidth {
            // 4. Subir de uno en uno: al día con el directo, con margen y
            //    velocidad de sobra.
            next = level + 1
        }
        // 5. Con poco margen, techo en la segunda más baja.
        if buffer < 15 { next = min(next, 1) }
        return max(0, min(top, next))
    }

    private func switchLevel(to newLevel: Int) {
        guard variants.indices.contains(newLevel), newLevel != level else { return }
        let now = Date()
        if newLevel < level { lastDown = now } else { lastUp = now }
        ProxyLog.log("calidad \(variants[level].height)p → \(variants[newLevel].height)p · margen \(Int(bufferAhead)) s · "
                     + "velocidad \(throughput.map { String(format: "%.2f", $0 / 1e6) } ?? "?") Mbps · atraso \(lagSegments)")
        let previous = level
        level = newLevel
        if let cached = playlists[newLevel], now.timeIntervalSince(cached.at) < targetDuration {
            if alignment(of: cached.playlist, level: newLevel) == false {
                ProxyLog.log("las calidades no van sincronizadas → calidad fija")
                abrEnabled = false
                manualLevel = nil
                level = previous
            }
        } else {
            // Hasta tener su playlist no se pide nada de la calidad nueva.
            alignmentCheckFrom = previous
            pollNow()
        }
    }

    // MARK: - Reloj

    private func tick() {
        guard !stopped else { return }
        let now = Date()
        ticks += 1

        // Velocidad: solo cuenta mientras se descarga. Pedir y no recibir nada
        // durante más de lo que tarda un servidor en contestar también cuenta
        // (como cero): así un corte real hace bajar la estimación.
        let bytes = fetcher.takeReceivedBytes()
        silentFor = bytes > 0 || fetcher.activeCount == 0 ? 0 : silentFor + 0.25
        if fetcher.transferringCount > 0 || bytes > 0 || silentFor > 1.5 {
            let bits = Double(bytes * 8) / 0.25
            fastRate.add(bits, weight: 0.25)
            slowRate.add(bits, weight: 0.25)
        }
        fetcher.watchdog(now: now, hedgeAfter: max(2, targetDuration * 0.6))

        lagHistory.append((now, lagSegments))
        lagHistory.removeAll { now.timeIntervalSince($0.at) > 20 }
        if !caughtUp, lagSegments <= 1 || now.timeIntervalSince(startedAt) > 30 {
            caughtUp = true
            ProxyLog.log("al día con el directo · margen \(Int(bufferAhead)) s")
        }

        // Sin noticias de la playlist: la conexión de listas puede estar muerta.
        if now.timeIntervalSince(lastPlaylistSuccess) > max(8, 3 * targetDuration) {
            lastPlaylistSuccess = now
            ProxyLog.log("playlist sin responder → conexión nueva")
            fetcher.renewPlaylistConnection()
            pollInFlight = false
            pollID += 1
            poll()
        }

        if ticks % 2 == 0 { publishStatus() }
        if ticks % 240 == 1 { checkDiskSpace() }
        // Cada 10 s, por si la app se cierra de golpe (⌘Q, cuelgue…).
        if ticks % 40 == 0, playhead != nil, !recorded.isEmpty { saveSession() }
        checkReady()
        schedule()
    }

    private func publishStatus() {
        guard let handler = statusHandler else { return }
        // Al retomar lo guardado, las calidades aún no se han releído.
        let height = variants.indices.contains(level) ? variants[level].height : 0
        let status = Status(bufferAhead: bufferAhead, level: level, height: height,
                            throughput: throughput, behindLive: Double(lagSegments) * targetDuration,
                            lostSegments: lost, transferring: fetcher.transferringCount,
                            sourceDown: sourceDown)
        DispatchQueue.main.async { handler(status) }
    }

    private func checkDiskSpace() {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? .max
        // Con el disco casi lleno, solo 15 min para rebobinar.
        keepBehind = free < 3_000_000_000 ? 15 * 60 : 2 * 3600
    }

    // MARK: - Servidor local

    private func handle(_ path: String) -> LocalHTTPServer.Response? {
        if path == "/live.m3u8" {
            return .init(contentType: "application/vnd.apple.mpegurl", body: Data(playlistText().utf8))
        }
        guard path.hasPrefix("/seg/"), path.hasSuffix(".ts"),
              let sequence = Int(path.dropFirst("/seg/".count).dropLast(".ts".count)) else { return nil }
        let index = sequence - firstLocalSequence
        guard recorded.indices.contains(index),
              let data = try? Data(contentsOf: file(recorded[index].localSequence)) else { return nil }
        return .init(contentType: "video/mp2t", body: data)
    }

    private func playlistText() -> String {
        let maxDuration = recorded.map(\.duration).max() ?? targetDuration
        let first = recorded.first
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(Int(max(targetDuration, maxDuration).rounded(.up)))",
            "#EXT-X-MEDIA-SEQUENCE:\(firstLocalSequence)",
            // La etiqueta del primero no se escribe pero cuenta, así el número
            // de cada tramo no cambia al ir borrando por delante.
            "#EXT-X-DISCONTINUITY-SEQUENCE:\(evictedDiscontinuities + (first?.discontinuity == true ? 1 : 0))",
        ]
        if independentSegments { lines.append("#EXT-X-INDEPENDENT-SEGMENTS") }
        for (index, segment) in recorded.enumerated() {
            if index > 0, segment.discontinuity { lines.append("#EXT-X-DISCONTINUITY") }
            // Fecha propia (continua) para que el reproductor nos diga qué está viendo.
            if index == 0 || segment.discontinuity {
                lines.append("#EXT-X-PROGRAM-DATE-TIME:\(Self.isoFormatter.string(from: segment.date))")
            }
            lines.append("#EXTINF:\(String(format: "%.3f", segment.duration)),")
            lines.append("/seg/\(segment.localSequence).ts")
        }
        if upstreamEnded, jobs.isEmpty, let playlist = playlists[level]?.playlist,
           (nextSequence ?? 0) > playlist.lastSequence {
            lines.append("#EXT-X-ENDLIST")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Registro del grabador (solo en desarrollo): `log show --predicate 'subsystem == "KerterApp"'`.
enum ProxyLog {
    static var echo = false
    static let started = Date()
    private static let logger = Logger(subsystem: "KerterApp", category: "proxy")

    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        logger.notice("\(text, privacy: .public)")
        if echo { print(String(format: "[proxy %5.1f] ", Date().timeIntervalSince(started)) + text) }
        #endif
    }
}
