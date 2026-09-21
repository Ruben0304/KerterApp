import SwiftUI

/// Ajustes de la app. En Mac también es la ventana de Ajustes (⌘,).
struct SettingsView: View {
    @EnvironmentObject private var auth: AuthManager
    @AppStorage(PlaybackSettings.bufferKey) private var bufferSeconds = PlaybackSettings.defaultBuffer
    @AppStorage(PlaybackSettings.previewsKey) private var previewsEnabled = PlaybackSettings.defaultPreviews
    @AppStorage(PlaybackSettings.proxyKey) private var proxyEnabled = PlaybackSettings.defaultProxy
    @AppStorage(PlaybackSettings.waitForMarginKey) private var waitForMargin = PlaybackSettings.defaultWaitForMargin
    @AppStorage(SportsFilterSettings.key) private var enabledSportsRaw = SportsFilterSettings.defaultRaw

    private var accountName: String {
        if auth.isDemo { return "Modo demo" }
        return auth.user?.name ?? auth.user?.email ?? "Mi cuenta"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(accountName)
                            .font(.body.weight(.semibold))
                        if let email = auth.user?.email, !auth.isDemo {
                            Text(email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button(role: .destructive) { auth.signOut() } label: {
                    Label(auth.isDemo ? "Salir del demo" : "Cerrar sesión",
                          systemImage: "rectangle.portrait.and.arrow.right")
                }
            } header: {
                Text("Mi cuenta")
            }

            #if os(iOS)
            Section {
                NavigationLink(destination: PairTVView()) {
                    Label("Vincular TV", systemImage: "tv.and.mediabox")
                }
            } header: {
                Text("DeporTV")
            } footer: {
                Text("Vincula esta cuenta con la app de Fire TV/Android TV sin teclear la contraseña con el mando — ambos dispositivos deben estar en la misma red Wi-Fi.")
            }
            #endif

            Section {
                ForEach(SportsFilterSettings.allSports, id: \.self) { sport in
                    Toggle(sport, isOn: sportBinding(sport))
                }
            } header: {
                Text("Deportes en Inicio")
            } footer: {
                Text("""
                Elige qué deportes aparecen en Inicio (en vivo, competiciones, \
                rieles). Por ejemplo, deja solo Fútbol y UFC para que no se \
                llene de otros deportes. El resto de la app no cambia.
                """)
            }

            Section {
                Picker(selection: $bufferSeconds) {
                    ForEach(PlaybackSettings.bufferOptions, id: \.self) { seconds in
                        Text(PlaybackSettings.label(seconds)).tag(seconds)
                    }
                } label: {
                    Label("Margen del directo", systemImage: "timer")
                }
                Toggle(isOn: $previewsEnabled) {
                    Label("Vistas previas en vivo", systemImage: "play.rectangle")
                }
            } header: {
                Text("Reproducción")
            } footer: {
                Text("""
                Los partidos se ven con este retraso respecto al directo real para \
                ir descargando por delante: si la conexión se corta un momento, el \
                video sigue sin pararse. Más margen aguanta cortes más largos, pero \
                ves el partido más tarde. Se aplica al abrir un canal.

                Las vistas previas en vivo de la portada y de cada partido gastan \
                conexión (nunca mientras ves un canal). Con una conexión justa, \
                apágalas.
                """)
            }

            Section {
                Toggle(isOn: $proxyEnabled) {
                    Label("Acelerador de conexión", systemImage: "bolt.horizontal")
                }
                Toggle(isOn: $waitForMargin) {
                    Label("Esperar al margen antes de empezar", systemImage: "hourglass")
                }
                .disabled(!proxyEnabled)
            } header: {
                Text("Conexión")
            } footer: {
                Text("""
                El acelerador baja el directo por varias conexiones a la vez y lo \
                va guardando en el Mac: los canales solo guardan 15–30 s, pero lo \
                grabado no caduca, así que el margen aguanta cortes más largos, \
                puedes pausar para juntar colchón y rebobinar. La calidad se ajusta \
                sola, priorizando que no se pare.

                Con "Esperar al margen", al abrir un canal se espera a tener el \
                margen completo antes de empezar (tarda más en arrancar, pero \
                aguanta cortes largos desde el primer minuto).
                """)
            }
        }
        .formStyle(.grouped)
    }

    private func sportBinding(_ sport: String) -> Binding<Bool> {
        Binding(
            get: { SportsFilterSettings.enabledSet(from: enabledSportsRaw).contains(sport) },
            set: { isOn in
                var set = SportsFilterSettings.enabledSet(from: enabledSportsRaw)
                if isOn { set.insert(sport) } else { set.remove(sport) }
                enabledSportsRaw = SportsFilterSettings.raw(from: set)
            }
        )
    }
}
