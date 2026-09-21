import Foundation

/// Descarga de fragmentos por varias conexiones independientes ("carriles").
///
/// Cada carril es su propia `URLSession` y por tanto su propia conexión TCP.
/// Con HTTP/2 todo lo de una sesión va por una sola conexión, y ahí un paquete
/// perdido frena todas las descargas a la vez; con carriles separados, una
/// pérdida solo frena a uno. Además:
/// - un fragmento puede partirse en trozos (`Range`) entre carriles libres;
/// - un trozo que se queda sin recibir datos abandona su conexión (que
///   probablemente esté muerta sin saberlo) y sigue por otra desde el byte
///   donde iba;
/// - si un trozo se atrasa y hay un carril libre, se pide también por ahí y
///   gana el primero que termine (petición de respaldo).
///
/// Todo corre en la cola del grabador (`queue`): sin candados.
final class SegmentFetcher: NSObject, URLSessionDataDelegate {
    enum Failure: Error { case notFound, http(Int), cancelled }

    final class Job {
        let sequence: Int
        let url: URL
        fileprivate var pieces: [Piece] = []
        fileprivate var total: Int?
        fileprivate var finished = false
        fileprivate let completion: (Result<Data, Failure>) -> Void

        fileprivate init(sequence: Int, url: URL, completion: @escaping (Result<Data, Failure>) -> Void) {
            self.sequence = sequence
            self.url = url
            self.completion = completion
        }
    }

    /// Un rango de bytes de un fragmento. `data` siempre cubre
    /// `start ..< start + data.count`.
    fileprivate final class Piece {
        let job: Job
        let start: Int
        var end: Int?                 // inclusivo; nil = hasta el final
        var data = Data()
        var task: URLSessionDataTask?
        var lane: Lane?
        var readyAt = Date.distantPast
        var requestedAt = Date()
        var firstByteAt: Date?
        var lastByteAt: Date?
        var done = false
        var attempts = 0
        var notFound = 0
        weak var hedge: Piece?        // su petición de respaldo
        weak var hedgeOf: Piece?      // si esta es el respaldo de otra

        init(job: Job, start: Int, end: Int?) {
            self.job = job
            self.start = start
            self.end = end
        }

        var nextOffset: Int { start + data.count }
        var remaining: Int? { end.map { max(0, $0 - nextOffset + 1) } }
    }

    fileprivate final class Lane {
        var session: URLSession
        var piece: Piece?
        init(session: URLSession) { self.session = session }
    }

    /// Trozos más pequeños no compensan el viaje de ida y vuelta de pedirlos.
    static let minPiece = 128 * 1024
    static let userAgent = "AppleCoreMedia/1.0.0 (Macintosh; U; Intel Mac OS X; es_es) KerterApp"

    let laneCount: Int
    private let queue: DispatchQueue
    private let delegateQueue: OperationQueue
    private var lanes: [Lane] = []
    private var playlistSession: URLSession!
    private var active: [ObjectIdentifier: Piece] = [:]
    private var waiting: [Piece] = []
    private var receivedBytes = 0
    /// El servidor ignora `Range`: nada de trozos ni respaldos.
    private(set) var rangesUnsupported = false
    private var outageUntil: Date?
    #if DEBUG
    private(set) var recentLocalPorts: [Int] = []
    #endif

    init(queue: DispatchQueue, laneCount: Int = 3) {
        self.queue = queue
        self.laneCount = laneCount
        delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        super.init()
        lanes = (0..<laneCount).map { _ in Lane(session: makeSession(delegate: self)) }
        playlistSession = makeSession(delegate: nil)
    }

    private func makeSession(delegate: URLSessionDelegate?) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 1
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 300
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.networkServiceType = .avStreaming
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        return URLSession(configuration: config, delegate: delegate, delegateQueue: delegateQueue)
    }

    // MARK: - API (siempre desde `queue`)

    /// Carriles libres que no están reservados para reintentos pendientes.
    var idleLaneCount: Int {
        max(0, lanes.filter { $0.piece == nil }.count - waiting.count)
    }

    /// Trozos pedidos (con o sin datos aún).
    var activeCount: Int { active.count }

    /// Carriles recibiendo datos ahora mismo.
    var transferringCount: Int {
        active.values.filter { $0.firstByteAt != nil && !$0.done }.count
    }

    private var inOutage: Bool { (outageUntil ?? .distantPast) > Date() }

    /// Bytes recibidos desde la última llamada.
    func takeReceivedBytes() -> Int {
        defer { receivedBytes = 0 }
        return receivedBytes
    }

    /// Baja un fragmento. Si `allowSplit` y se espera grande, se parte entre
    /// los carriles libres: el último trozo va abierto (`bytes=N-`), así que
    /// aunque la estimación falle no se baja nada de más.
    @discardableResult
    func fetch(sequence: Int, url: URL, estimatedSize: Int?, allowSplit: Bool,
               completion: @escaping (Result<Data, Failure>) -> Void) -> Job {
        let job = Job(sequence: sequence, url: url, completion: completion)
        var count = 1
        if allowSplit, !rangesUnsupported, let size = estimatedSize {
            count = max(1, min(idleLaneCount, 3, size / Self.minPiece))
        }
        if count > 1, let size = estimatedSize {
            let bounds = (0..<count).map { size * $0 / count }
            job.pieces = bounds.enumerated().map { index, lower in
                Piece(job: job, start: lower, end: index + 1 < count ? bounds[index + 1] - 1 : nil)
            }
        } else {
            job.pieces = [Piece(job: job, start: 0, end: nil)]
        }
        waiting.append(contentsOf: job.pieces)
        dispatch()
        return job
    }

    func cancel(_ job: Job) {
        fail(job, .cancelled)
    }

    /// Texto (playlists) por una conexión aparte: enterarse de un fragmento
    /// nuevo no espera a que acabe una descarga pesada.
    func fetchText(_ url: URL, timeout: TimeInterval, completion: @escaping (Result<(String, URL), Error>) -> Void) {
        guard !inOutage else {
            queue.asyncAfter(deadline: .now() + 0.3) { completion(.failure(URLError(.notConnectedToInternet))) }
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        playlistSession.dataTask(with: request) { data, response, error in
            // Se ejecuta en `delegateQueue`, es decir, en `queue`.
            guard error == nil, let data, let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let text = String(data: data, encoding: .utf8) else {
                completion(.failure(error ?? URLError(.badServerResponse)))
                return
            }
            completion(.success((text, http.url ?? url)))
        }.resume()
    }

    func renewPlaylistConnection() {
        playlistSession.invalidateAndCancel()
        playlistSession = makeSession(delegate: nil)
    }

    /// Cambio de red o atasco general: todas las conexiones viejas pueden
    /// estar muertas sin saberlo. Se rehacen y cada trozo sigue donde iba.
    func resetAll() {
        for piece in Array(active.values) { abandon(piece, renewConnection: false) }
        for lane in lanes { renew(lane) }
        renewPlaylistConnection()
        dispatch()
    }

    /// Solo para pruebas: la red "desaparece" durante `seconds`.
    func simulateOutage(_ seconds: TimeInterval) {
        outageUntil = Date().addingTimeInterval(seconds)
        resetAll()
        queue.asyncAfter(deadline: .now() + seconds + 0.05) { [weak self] in self?.dispatch() }
    }

    func invalidate() {
        for piece in Array(active.values) { detach(piece) }
        waiting.removeAll()
        lanes.forEach { $0.session.invalidateAndCancel() }
        playlistSession.invalidateAndCancel()
    }

    /// Vigilancia periódica: conexiones mudas y peticiones de respaldo.
    func watchdog(now: Date, hedgeAfter: TimeInterval) {
        for piece in Array(active.values) {
            let silence = now.timeIntervalSince(piece.lastByteAt ?? piece.requestedAt)
            // Antes del primer byte se tolera más (latencia del servidor).
            if silence > (piece.firstByteAt == nil ? 4 : 3) {
                ProxyLog.log("seg \(piece.job.sequence) [\(piece.start)-]: \(Int(silence)) s sin datos → conexión nueva")
                abandon(piece, renewConnection: true)
            }
        }
        if !rangesUnsupported, !inOutage, idleLaneCount > 0 {
            let late = active.values.filter { piece in
                piece.hedge == nil && piece.hedgeOf == nil && !piece.done
                    && now.timeIntervalSince(piece.requestedAt) > hedgeAfter
                    && (piece.remaining ?? .max) > 24 * 1024
            }
            if let piece = late.min(by: { ($0.job.sequence, $0.start) < ($1.job.sequence, $1.start) }) {
                let hedge = Piece(job: piece.job, start: piece.nextOffset, end: piece.end)
                hedge.hedgeOf = piece
                piece.hedge = hedge
                piece.job.pieces.append(hedge)
                waiting.append(hedge)
                ProxyLog.log("seg \(piece.job.sequence): va lento → respaldo desde el byte \(hedge.start)")
            }
        }
        dispatch()
    }

    // MARK: - Reparto

    private func dispatch() {
        guard !inOutage else { return }
        let now = Date()
        waiting.removeAll { $0.job.finished }
        waiting.sort { ($0.job.sequence, $0.start) < ($1.job.sequence, $1.start) }
        for lane in lanes where lane.piece == nil {
            guard let index = waiting.firstIndex(where: { $0.readyAt <= now }) else { break }
            start(waiting.remove(at: index), on: lane)
        }
    }

    private func start(_ piece: Piece, on lane: Lane) {
        var request = URLRequest(url: piece.job.url)
        if piece.start > 0 || piece.end != nil {
            request.setValue("bytes=\(piece.start)-\(piece.end.map(String.init) ?? "")", forHTTPHeaderField: "Range")
        }
        let task = lane.session.dataTask(with: request)
        piece.task = task
        piece.lane = lane
        piece.requestedAt = Date()
        piece.firstByteAt = nil
        piece.lastByteAt = nil
        lane.piece = piece
        active[ObjectIdentifier(task)] = piece
        task.resume()
    }

    private func requeue(_ piece: Piece, delay: TimeInterval) {
        piece.readyAt = Date().addingTimeInterval(delay)
        waiting.append(piece)
        if delay > 0 {
            queue.asyncAfter(deadline: .now() + delay + 0.01) { [weak self] in self?.dispatch() }
        }
    }

    private static func backoff(_ attempts: Int) -> TimeInterval {
        min(2, 0.15 * pow(2, Double(max(0, attempts - 1))))
    }

    private func renew(_ lane: Lane) {
        lane.session.invalidateAndCancel()
        lane.session = makeSession(delegate: self)
    }

    /// Suelta el trozo de su tarea y su carril (sin tocar sus datos).
    private func detach(_ piece: Piece) {
        if let task = piece.task {
            active[ObjectIdentifier(task)] = nil
            task.cancel()
        }
        piece.task = nil
        if let lane = piece.lane, lane.piece === piece { lane.piece = nil }
        piece.lane = nil
    }

    /// El trozo se cortó o se quedó mudo: lo que falta se pide otra vez.
    private func abandon(_ piece: Piece, renewConnection: Bool) {
        let lane = piece.lane
        detach(piece)
        if renewConnection, let lane { renew(lane) }
        piece.attempts += 1
        let job = piece.job

        if let original = piece.hedgeOf {
            // Un respaldo que falla se descarta: el original sigue.
            original.hedge = nil
            job.pieces.removeAll { $0 === piece }
        } else if let hedge = piece.hedge, !hedge.done {
            // El original falla con un respaldo en marcha: se queda con lo que
            // tenía hasta donde empieza el respaldo, que sigue solo.
            piece.data = piece.data.prefix(max(0, hedge.start - piece.start))
            piece.end = hedge.start - 1
            piece.done = true
            piece.hedge = nil
            hedge.hedgeOf = nil
        } else if piece.data.isEmpty {
            requeue(piece, delay: Self.backoff(piece.attempts))
        } else {
            let rest = Piece(job: job, start: piece.nextOffset, end: piece.end)
            rest.attempts = piece.attempts
            piece.end = piece.nextOffset - 1
            piece.done = true
            job.pieces.append(rest)
            requeue(rest, delay: Self.backoff(rest.attempts))
        }
        checkJob(job)
    }

    private func complete(_ piece: Piece) {
        piece.done = true
        let job = piece.job
        // Respaldo: el primero que termina gana.
        if let hedge = piece.hedge, !hedge.done {
            detach(hedge)
            job.pieces.removeAll { $0 === hedge }
            waiting.removeAll { $0 === hedge }
            piece.hedge = nil
        }
        if let original = piece.hedgeOf, !original.done {
            detach(original)
            waiting.removeAll { $0 === original }
            original.data = original.data.prefix(max(0, piece.start - original.start))
            original.end = piece.start - 1
            original.done = true
            original.hedge = nil
            piece.hedgeOf = nil
        }
        checkJob(job)
    }

    private func checkJob(_ job: Job) {
        guard !job.finished, job.pieces.allSatisfy(\.done) else { return }
        var data = Data()
        var offset = 0
        for piece in job.pieces.sorted(by: { $0.start < $1.start }) where !piece.data.isEmpty {
            if piece.start > offset {
                // Hueco (no debería pasar): se pide lo que falta.
                return requestMissing(job, from: offset, to: piece.start - 1)
            }
            let overlap = offset - piece.start
            if overlap < piece.data.count {
                data.append(piece.data.dropFirst(overlap))
                offset = piece.start + piece.data.count
            }
        }
        if let total = job.total, offset < total {
            return requestMissing(job, from: offset, to: total - 1)
        }
        guard !data.isEmpty else { return fail(job, .http(0)) }
        job.finished = true
        job.pieces.removeAll()
        job.completion(.success(data))
    }

    private func requestMissing(_ job: Job, from lower: Int, to upper: Int) {
        let piece = Piece(job: job, start: lower, end: upper)
        job.pieces.append(piece)
        requeue(piece, delay: 0)
        dispatch()
    }

    private func fail(_ job: Job, _ failure: Failure) {
        guard !job.finished else { return }
        job.finished = true
        job.pieces.forEach(detach)
        waiting.removeAll { $0.job === job }
        job.pieces.removeAll()
        job.completion(.failure(failure))
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let piece = active[ObjectIdentifier(dataTask)] else { return completionHandler(.cancel) }
        let job = piece.job
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0

        switch status {
        case 206:
            if let total = Self.totalSize(http) {
                job.total = total
                if piece.end.map({ $0 > total - 1 }) ?? true { piece.end = total - 1 }
            }
            completionHandler(.allow)

        case 200:
            if piece.start > 0 || piece.end != nil || job.pieces.count > 1 {
                // El servidor ignora `Range` y manda el archivo entero: este
                // trozo pasa a ser el fragmento completo.
                rangesUnsupported = true
                for other in job.pieces where other !== piece {
                    detach(other)
                    waiting.removeAll { $0 === other }
                }
                let whole = Piece(job: job, start: 0, end: nil)
                whole.task = piece.task
                whole.lane = piece.lane
                whole.requestedAt = piece.requestedAt
                piece.lane?.piece = whole
                active[ObjectIdentifier(dataTask)] = whole
                job.pieces = [whole]
                return self.urlSession(session, dataTask: dataTask, didReceive: response,
                                       completionHandler: completionHandler)
            }
            if response.expectedContentLength > 0 {
                job.total = Int(response.expectedContentLength)
                piece.end = job.total! - 1
            }
            completionHandler(.allow)

        case 416:
            // Trozo más allá del final: el fragmento era más pequeño de lo estimado.
            if let total = Self.totalSize(http) { job.total = total }
            detach(piece)
            completionHandler(.cancel)
            piece.end = piece.start - 1
            complete(piece)

        case 404, 410:
            detach(piece)
            completionHandler(.cancel)
            piece.notFound += 1
            if piece.notFound >= 2 {
                fail(job, .notFound)
            } else {
                requeue(piece, delay: 0.5)   // un fragmento recién publicado a veces tarda un instante
            }

        default:
            detach(piece)
            completionHandler(.cancel)
            piece.attempts += 1
            if piece.attempts > 6 {
                fail(job, .http(status))
            } else {
                requeue(piece, delay: Self.backoff(piece.attempts))
            }
        }
        dispatch()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let piece = active[ObjectIdentifier(dataTask)] else { return }
        let now = Date()
        if piece.firstByteAt == nil { piece.firstByteAt = now }
        piece.lastByteAt = now
        var chunk = data
        if let remaining = piece.remaining, chunk.count > remaining { chunk = chunk.prefix(remaining) }
        piece.data.append(chunk)
        receivedBytes += chunk.count
        if piece.remaining == 0 {
            detach(piece)
            complete(piece)
            dispatch()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let piece = active[ObjectIdentifier(task)] else { return }
        if error == nil, (piece.remaining ?? 0) == 0 {
            detach(piece)
            if piece.end == nil {
                piece.end = piece.nextOffset - 1
                if piece.start == 0, piece.job.total == nil { piece.job.total = piece.data.count }
            }
            complete(piece)
        } else {
            // Cortado a medias (o error de red): lo que falta, por una conexión nueva.
            abandon(piece, renewConnection: error != nil)
        }
        dispatch()
    }

    #if DEBUG
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let port = metrics.transactionMetrics.last?.localPort else { return }
        recentLocalPorts.append(port)
        if recentLocalPorts.count > 30 { recentLocalPorts.removeFirst() }
    }
    #endif

    /// `Content-Range: bytes 0-99/1234` (o `bytes */1234`) → 1234.
    private static func totalSize(_ response: HTTPURLResponse?) -> Int? {
        guard let value = response?.value(forHTTPHeaderField: "Content-Range"),
              let slash = value.lastIndex(of: "/") else { return nil }
        return Int(value[value.index(after: slash)...])
    }
}
