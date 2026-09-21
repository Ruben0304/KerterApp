import Foundation

/// Respuesta flexible del endpoint de login.
/// El nombre del campo del token varía según el backend, así que probamos varios.
struct AuthResponse: Decodable {
    var token: String?
    var user: User?

    private static let tokenKeys = ["token", "accessToken", "access_token",
                                    "jwt", "authToken", "idToken", "bearer", "session"]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        token = c.firstString(Self.tokenKeys)

        // El token (y el usuario) pueden venir anidados bajo "data".
        let nested = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("data"))
        if token == nil { token = nested?.firstString(Self.tokenKeys) }

        if let u = try? c.decode(User.self, forKey: AnyKey("user")) {
            user = u
        } else if let n = nested, let u = try? n.decode(User.self, forKey: AnyKey("user")) {
            user = u
        } else if let u = try? c.decode(User.self, forKey: AnyKey("data")) {
            user = u
        } else {
            user = try? User(from: decoder)
        }
    }
}
