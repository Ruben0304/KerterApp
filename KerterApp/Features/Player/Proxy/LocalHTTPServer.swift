import Foundation
import Network

/// Servidor HTTP mínimo (escucha en la red local, para que AirPlay y Google
/// Cast puedan pedirle el video al dispositivo) para que los receptores lean
/// lo grabado. Cubre HLS con GET/HEAD/OPTIONS, `Range`, CORS y keep-alive.
/// Todo corre en la cola del grabador, así que el manejador puede leer su
/// estado sin candados.
final class LocalHTTPServer {
    struct Response {
        var status = 200
        var contentType: String
        var body: Data
    }

    private let queue: DispatchQueue
    private let handler: (String) -> Response?
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private(set) var port: UInt16 = 0

    init(queue: DispatchQueue, handler: @escaping (String) -> Response?) {
        self.queue = queue
        self.handler = handler
    }

    /// Arranca en un puerto libre de todas las interfaces. `ready` se llama una vez.
    func start(ready: @escaping (Bool) -> Void) {
        let parameters = NWParameters.tcp
        // Sin restricción a loopback: el receptor AirPlay o Cast descarga el
        // video directamente de aquí, por la IP de la red local.
        guard let listener = try? NWListener(using: parameters) else {
            ready(false)
            return
        }
        self.listener = listener
        var reported = false
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, !reported else { return }
            switch state {
            case .ready:
                reported = true
                self.port = listener.port?.rawValue ?? 0
                ready(self.port != 0)
            case .failed, .cancelled:
                reported = true
                ready(false)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections[id] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, pending: Data())
    }

    private func receive(on connection: NWConnection, pending: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = pending
            if let data { buffer.append(data) }
            // Con keep-alive pueden llegar varias peticiones seguidas.
            while let end = buffer.range(of: Self.headerEnd) {
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                buffer = Data(buffer[end.upperBound...])
                self.respond(to: head, on: connection)
            }
            if isComplete || error != nil || buffer.count > 64 * 1024 {
                connection.cancel()
                return
            }
            self.receive(on: connection, pending: buffer)
        }
    }

    private static let headerEnd = Data("\r\n\r\n".utf8)

    private func respond(to head: String, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ") ?? []
        guard request.count >= 2 else { return send(400, on: connection) }
        let method = request[0]
        guard method == "GET" || method == "HEAD" || method == "OPTIONS" else {
            return send(405, on: connection)
        }

        // El receptor web de Google Cast comprueba CORS antes de leer HLS.
        if method == "OPTIONS" { return send(204, includeBody: false, on: connection) }

        let path = String(request[1].split(separator: "?").first ?? "")
        if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint, "\(host)" != "127.0.0.1" {
            ProxyLog.log("HTTP remoto \(host) \(method) \(path)")
        }
        guard let response = handler(path) else { return send(404, on: connection) }

        var status = response.status
        var body = response.body
        var extra = ""
        if status == 200, let range = Self.header("range", in: lines) {
            guard let (lower, upper) = Self.byteRange(range, count: body.count) else {
                return send(416, extra: "Content-Range: bytes */\(body.count)\r\n", on: connection)
            }
            extra = "Content-Range: bytes \(lower)-\(upper)/\(body.count)\r\n"
            body = body.subdata(in: lower..<(upper + 1))
            status = 206
        }
        send(status, contentType: response.contentType, body: body, extra: extra,
             includeBody: method == "GET", on: connection)
    }

    private func send(_ status: Int, contentType: String = "text/plain", body: Data = Data(),
                      extra: String = "", includeBody: Bool = true, on connection: NWConnection) {
        let reason = [200: "OK", 204: "No Content", 206: "Partial Content", 400: "Bad Request", 404: "Not Found",
                      405: "Method Not Allowed", 416: "Range Not Satisfiable"][status] ?? "Error"
        let header = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Accept-Ranges: bytes\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n"
            + "Access-Control-Allow-Headers: Range, Accept, Content-Type\r\n"
            + "Access-Control-Expose-Headers: Content-Length, Content-Range, Accept-Ranges\r\n"
            + "Access-Control-Allow-Private-Network: true\r\n"
            + "Connection: keep-alive\r\n"
            + extra + "\r\n"
        var out = Data(header.utf8)
        if includeBody { out.append(body) }
        connection.send(content: out, completion: .contentProcessed { error in
            if error != nil { connection.cancel() }
        })
    }

    private static func header(_ name: String, in lines: [String]) -> String? {
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == name else { continue }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// `bytes=a-b`, `bytes=a-` o `bytes=-n` → rango inclusivo dentro de `count`.
    private static func byteRange(_ value: String, count: Int) -> (Int, Int)? {
        guard value.hasPrefix("bytes="), count > 0 else { return nil }
        let spec = value.dropFirst("bytes=".count).split(separator: ",").first ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let suffix = Int(parts[1]), suffix > 0 else { return nil }
            return (max(0, count - suffix), count - 1)
        }
        guard let lower = Int(parts[0]), lower < count else { return nil }
        let upper = parts[1].isEmpty ? count - 1 : min(Int(parts[1]) ?? count - 1, count - 1)
        return upper >= lower ? (lower, upper) : nil
    }
}

extension LocalHTTPServer {
    /// IPv4 del dispositivo en la red local (Wi-Fi/Ethernet), si hay.
    static func lanAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var found: [(name: String, ip: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  Int32(ifa.ifa_flags) & IFF_UP != 0, Int32(ifa.ifa_flags) & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            found.append((name, String(cString: host)))
        }
        // en0 suele ser el Wi-Fi.
        return (found.first { $0.name == "en0" } ?? found.first)?.ip
    }
}
