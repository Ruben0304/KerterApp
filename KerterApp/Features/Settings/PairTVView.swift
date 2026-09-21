import SwiftUI
import Network

/// Emparejar esta cuenta con DeporTV (Fire TV/Android TV) por red local:
/// se descubre la TV por Bonjour (`_deportv._tcp`, el mismo servicio que
/// anuncia `PairingViewModel.kt`) y se le mandan las credenciales ya
/// guardadas en el Keychain, cifradas con el código de 6 dígitos que se ve
/// en la pantalla de la TV.
private struct DiscoveredTV: Identifiable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

@MainActor
private final class PairTVViewModel: ObservableObject {
    enum Phase: Equatable {
        case searching
        case codeEntry(host: String, port: UInt16)
        case pairing
        case success
        case failure(String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.searching, .searching), (.pairing, .pairing), (.success, .success): return true
            case let (.codeEntry(h1, p1), .codeEntry(h2, p2)): return h1 == h2 && p1 == p2
            case let (.failure(m1), .failure(m2)): return m1 == m2
            default: return false
            }
        }
    }

    @Published var discovered: [DiscoveredTV] = []
    @Published var phase: Phase = .searching

    private var browser: NWBrowser?
    private var connection: NWConnection?

    func startBrowsing() {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_deportv._tcp", domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let tvs: [DiscoveredTV] = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredTV(id: name, name: name, endpoint: result.endpoint)
            }
            Task { @MainActor in self?.discovered = tvs }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
    }

    /// Abre una conexión de prueba solo para que el sistema resuelva el
    /// host:puerto real detrás del nombre Bonjour — se cierra en cuanto se
    /// obtiene, antes de mandar nada.
    func select(_ tv: DiscoveredTV) {
        let connection = NWConnection(to: tv.endpoint, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            guard let remote = connection.currentPath?.remoteEndpoint,
                  case let .hostPort(host, port) = remote else { return }
            let hostString = Self.hostString(host)
            Task { @MainActor in
                self?.phase = .codeEntry(host: hostString, port: port.rawValue)
                connection.cancel()
            }
        }
        connection.start(queue: .main)
    }

    private nonisolated static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address):
            let raw = "\(address)"
            return raw.split(separator: "%").first.map(String.init) ?? raw
        case .name(let name, _): return name
        @unknown default: return ""
        }
    }

    func pair(host: String, port: UInt16, code: String, email: String, password: String) async {
        phase = .pairing
        guard let payload = PairingCrypto.encrypt("\(email)\u{1}\(password)", code: code),
              let url = URL(string: "http://\(host):\(port)/pair") else {
            phase = .failure("No se pudo preparar el emparejamiento.")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                phase = .success
            } else {
                phase = .failure("Revisa el código — no coincide con el de la TV.")
            }
        } catch {
            phase = .failure("No se pudo conectar con la TV. Comprueba que estáis en la misma red Wi-Fi.")
        }
    }
}

struct PairTVView: View {
    @EnvironmentObject private var auth: AuthManager
    @StateObject private var viewModel = PairTVViewModel()
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        Form {
            switch viewModel.phase {
            case .searching:
                Section {
                    if viewModel.discovered.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Buscando tu TV en la red…").foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(viewModel.discovered) { tv in
                            Button { viewModel.select(tv) } label: {
                                Label(tv.name, systemImage: "tv")
                            }
                        }
                    }
                } footer: {
                    Text("""
                    Abre "Vincular con el teléfono" en la pantalla de inicio de \
                    sesión de DeporTV — debe estar en esta misma red Wi-Fi.
                    """)
                }

            case .codeEntry(let host, let port):
                Section {
                    TextField("Código de 6 dígitos", text: $code)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .focused($codeFocused)
                    Button("Vincular") {
                        Task {
                            await viewModel.pair(host: host, port: port, code: code,
                                                 email: auth.savedEmail, password: auth.savedPassword)
                        }
                    }
                    .disabled(code.count != 6)
                } header: {
                    Text("Código de la TV")
                } footer: {
                    Text("Escribe el código de 6 dígitos que aparece en la pantalla de la TV.")
                }

            case .pairing:
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Vinculando…")
                    }
                }

            case .success:
                Section {
                    Label("¡Vinculado! Ya puedes ver Kerter+ en tu TV.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }

            case .failure(let message):
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Reintentar") {
                        code = ""
                        viewModel.phase = .searching
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Vincular TV")
        .onAppear { viewModel.startBrowsing() }
        .onDisappear { viewModel.stopBrowsing() }
        .onChange(of: viewModel.phase) { _, newPhase in
            if case .codeEntry = newPhase { codeFocused = true }
        }
    }
}
