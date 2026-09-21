import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case http(Int, String?)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "URL inválida."
        case .invalidResponse: return "Respuesta inválida del servidor."
        case .http(let code, let msg):
            if code == 401 { return "Sesión expirada o credenciales incorrectas." }
            return msg ?? "Error del servidor (\(code))."
        case .decoding: return "No se pudo interpretar la respuesta del servidor."
        }
    }
}

/// Cliente HTTP hacia el backend de Kerter+. `async/await` sobre URLSession.
final class APIClient {
    static let shared = APIClient()

    private let session: URLSession
    /// Token Bearer actual; lo setea el AuthManager al iniciar sesión.
    var authToken: String?

    init(session: URLSession = .shared) {
        self.session = session
    }

    private static let decoder = JSONDecoder()

    // MARK: - Endpoints

    func login(email: String, password: String) async throws -> AuthResponse {
        let payload: [String: String] = ["email": email, "password": password]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await requestData("/auth/login", method: "POST", body: body)
        #if DEBUG
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            print("[LOGIN] campos de la respuesta:", obj.keys.sorted())
        }
        #endif
        do { return try Self.decoder.decode(AuthResponse.self, from: data) }
        catch { throw APIError.decoding(error) }
    }

    func fetchChannels() async throws -> [Channel] {
        let data = try await requestData("/channels/public", method: "GET")
        #if DEBUG
        Self.debugDump(data, name: "channels.json")
        #endif
        return try Self.decodeChannelList(data)
    }

    /// Cartelera: asignaciones evento → canal para una fecha (yyyy-MM-dd).
    func fetchAssignments(date: String) async throws -> [Assignment] {
        let data = try await requestData("/assignments?date=\(date)", method: "GET")
        #if DEBUG
        Self.debugDump(data, name: "assignments.json")
        #endif
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return (try? dec.decode([Assignment].self, from: data)) ?? []
    }

    // MARK: - Core

    private func request<T: Decodable>(_ path: String, method: String,
                                       body: Data? = nil, as type: T.Type) async throws -> T {
        let data = try await requestData(path, method: method, body: body)
        do { return try Self.decoder.decode(T.self, from: data) }
        catch { throw APIError.decoding(error) }
    }

    private func requestData(_ path: String, method: String, body: Data? = nil) async throws -> Data {
        guard let url = URL(string: AppConfig.apiBaseURL.absoluteString + path) else {
            throw APIError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let authToken {
            req.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }
        #if DEBUG
        print("[API] \(method) \(path) → \(http.statusCode) (\(data.count) bytes)")
        #endif
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, Self.extractMessage(data))
        }
        return data
    }

    /// El backend puede devolver `[...]` directo o envuelto en `{data|channels|results:[...]}`.
    private static func decodeChannelList(_ data: Data) throws -> [Channel] {
        if let arr = try? decoder.decode([Channel].self, from: data) { return arr }
        struct Wrap: Decodable {
            let data: [Channel]?
            let channels: [Channel]?
            let results: [Channel]?
            let items: [Channel]?
        }
        if let w = try? decoder.decode(Wrap.self, from: data) {
            return w.data ?? w.channels ?? w.results ?? w.items ?? []
        }
        throw APIError.decoding(NSError(domain: "KerterAPI", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Formato de lista de canales desconocido"]))
    }

    #if DEBUG
    /// Guarda la respuesta cruda en Caches/KerterDebug para inspeccionar la
    /// forma real de los datos durante el desarrollo. Solo en builds DEBUG.
    private static func debugDump(_ data: Data, name: String) {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KerterDebug", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try? data.write(to: file, options: .atomic)
        print("[API] respuesta guardada en", file.path)
    }
    #endif

    private static func extractMessage(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["message"] as? String ?? obj["error"] as? String ?? obj["msg"] as? String
    }
}
