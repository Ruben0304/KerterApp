import Foundation
import Combine

/// Estado de autenticación de la app (fuente de verdad para la UI).
@MainActor
final class AuthManager: ObservableObject {
    enum State: Equatable {
        case unauthenticated
        case authenticating
        case authenticated
        case demo
    }

    @Published private(set) var state: State = .unauthenticated
    @Published private(set) var user: User?
    @Published var errorMessage: String?

    private let api = APIClient.shared
    private let tokenKey = "kerter.token"
    private let savedEmailKey = "kerter.savedEmail"
    private let savedPasswordKey = "kerter.savedPassword"

    var isSignedIn: Bool { state == .authenticated || state == .demo }
    var isDemo: Bool { state == .demo }

    /// Últimas credenciales guardadas, para prellenar el formulario de login
    /// (evita tener que volver a escribir la contraseña en Mac/iPhone).
    var savedEmail: String { KeychainStore.get(savedEmailKey) ?? "" }
    var savedPassword: String { KeychainStore.get(savedPasswordKey) ?? "" }

    init() {
        if let token = loadToken() {
            api.authToken = token
            state = .authenticated // confiamos en el token guardado; un 401 nos devolverá al login
        }
    }

    func login(email: String, password: String) async {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = "Introduce tu correo y contraseña."
            return
        }
        errorMessage = nil
        state = .authenticating
        do {
            let resp = try await api.login(email: email, password: password)
            guard let token = resp.token else {
                throw APIError.http(200, "El servidor no devolvió un token de sesión.")
            }
            storeToken(token)
            KeychainStore.set(email, for: savedEmailKey)
            KeychainStore.set(password, for: savedPasswordKey)
            api.authToken = token
            user = resp.user ?? User(id: "me", name: nil, email: email)
            state = .authenticated
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .unauthenticated
        }
    }

    func enterDemo() {
        user = User(id: "demo", name: "Invitado", email: nil)
        errorMessage = nil
        state = .demo
    }

    // En desarrollo las compilaciones se firman a veces con certificados
    // distintos, y el Llavero de macOS no deja a una leer (ni reemplazar) lo
    // que guardó otra: la sesión se perdía en cada compilación. Solo en DEBUG
    // se guarda además en los ajustes de la app; en la versión final, solo
    // en el Llavero.
    private static let debugTokenKey = "debug.kerter.token"

    private func storeToken(_ token: String) {
        KeychainStore.set(token, for: tokenKey)
        #if DEBUG
        UserDefaults.standard.set(token, forKey: Self.debugTokenKey)
        #endif
    }

    private func loadToken() -> String? {
        if let token = KeychainStore.get(tokenKey) { return token }
        #if DEBUG
        return UserDefaults.standard.string(forKey: Self.debugTokenKey)
        #else
        return nil
        #endif
    }

    func signOut() {
        KeychainStore.remove(tokenKey)
        #if DEBUG
        UserDefaults.standard.removeObject(forKey: Self.debugTokenKey)
        #endif
        api.authToken = nil
        user = nil
        errorMessage = nil
        state = .unauthenticated
    }
}
