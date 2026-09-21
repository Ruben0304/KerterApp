import AVFoundation
import Network

// MARK: - Calidad automática para conexiones inestables

/// "Automática" pensada para conexiones lentas y que suben y bajan: AVPlayer
/// por su cuenta sube de calidad en cuanto ve un pico de velocidad y luego se
/// corta. Aquí se mide lo que llega de verdad (del log de acceso del item) y se
/// le pone techo con `preferredPeakBitRate`:
/// - el techo es el 70 % de lo más bajo que ha rendido la conexión en el
///   último minuto y medio (percentil 20), no de la media;
/// - baja al momento (y un escalón extra tras cada corte);
/// - solo sube de uno en uno y tras un minuto sin bajar.
@MainActor
final class BitrateGovernor {
    /// BANDWIDTH de cada variante con video, de menor a mayor.
    private var ladder: [Double] = []
    /// Índice del techo actual en `ladder` (nil = aún sin techo).
    private var level: Int?
    private var samples: [(time: Date, bps: Double)] = []
    private var lastBytes: Int64 = 0
    private var lastDuration: TimeInterval = 0
    private var lastDown = Date.distantPast
    private var lastUp = Date.distantPast

    private static let window: TimeInterval = 90
    private static let headroom = 0.7
    private static let upAfterDown: TimeInterval = 60
    private static let upAfterUp: TimeInterval = 30

    /// Techo que debe tener el item en modo automático (nil = sin techo).
    var cap: Double? { level.map { ladder[$0] * 1.01 } }

    func setLadder(_ bitRates: [Double]) {
        ladder = Array(Set(bitRates.filter { $0 > 0 })).sorted()
        level = nil
    }

    /// Item nuevo (reconexión): su log de acceso empieza de cero.
    func resetMeasurements() {
        lastBytes = 0
        lastDuration = 0
    }

    /// Toma una muestra. Devuelve `true` si `cap` ha cambiado.
    func tick(_ item: AVPlayerItem, now: Date = .now) -> Bool {
        guard ladder.count > 1, let events = item.accessLog()?.events else { return false }

        let bytes = events.reduce(Int64(0)) { $0 + max(0, $1.numberOfBytesTransferred) }
        let duration = events.reduce(0.0) { $0 + max(0, $1.transferDuration) }
        if bytes < lastBytes || duration < lastDuration {
            lastBytes = bytes
            lastDuration = duration
            return false
        }
        // Velocidad real mientras se descarga (no cuenta los ratos en que
        // AVPlayer no pide nada porque ya tiene buffer).
        let dBytes = bytes - lastBytes, dDuration = duration - lastDuration
        if dDuration >= 0.5, dBytes > 50_000 {
            samples.append((now, Double(dBytes) * 8 / dDuration))
            lastBytes = bytes
            lastDuration = duration
        }
        samples.removeAll { now.timeIntervalSince($0.time) > Self.window }
        guard samples.count >= 3 else { return false }

        let sorted = samples.map(\.bps).sorted()
        let safe = sorted[Int(Double(sorted.count - 1) * 0.2)]
        let target = ladder.lastIndex { $0 <= safe * Self.headroom } ?? 0
        let current = level ?? ladder.count - 1

        if target < current {
            return set(target, down: true, now: now)
        }
        if target > current,
           now.timeIntervalSince(lastDown) >= Self.upAfterDown,
           now.timeIntervalSince(lastUp) >= Self.upAfterUp {
            return set(current + 1, down: false, now: now)
        }
        return false
    }

    /// Tras un corte: un escalón por debajo de lo que se estaba viendo.
    /// Devuelve `true` si `cap` ha cambiado.
    func noteStall(_ item: AVPlayerItem, now: Date = .now) -> Bool {
        guard ladder.count > 1 else { return false }
        let playing = item.accessLog()?.events.last?.indicatedBitrate ?? 0
        let playingIndex = ladder.lastIndex { $0 <= playing * 1.01 } ?? (level ?? ladder.count - 1)
        let current = min(playingIndex, level ?? ladder.count - 1)
        return set(max(0, current - 1), down: true, now: now)
    }

    private func set(_ index: Int, down: Bool, now: Date) -> Bool {
        if down { lastDown = now } else { lastUp = now }
        guard index != level else { return false }
        level = index
        return true
    }
}

// MARK: - Estado de la red

enum NetworkPath {
    /// Emite si hay salida a la red cada vez que cambia (y una vez al empezar).
    static func updates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { continuation.yield($0.status == .satisfied) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "kerter.network-path"))
        }
    }
}
