import SwiftUI

@main
struct KerterApp: App {
    @StateObject private var auth = AuthManager()
    #if os(macOS)
    @StateObject private var playerCoordinator = PlayerCoordinator()
    #endif
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                #if os(macOS)
                .environmentObject(playerCoordinator)
                #endif
                // La app está bloqueada a modo oscuro: nunca claro.
                .preferredColorScheme(.dark)
        }
        #if os(macOS)
        // Sin barra de título: la app se ve full-bleed, sin la topbar del sistema.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 720)
        #endif

        #if os(macOS)
        // Ventana dedicada del reproductor: sin barra de título → pantalla completa
        // muestra solo el video.
        Window("Reproductor", id: "player") {
            PlayerWindowHost()
                // Pantalla completa nativa: la ventana pasa a su propio escritorio.
                .windowFullScreenBehavior(.enabled)
                .environmentObject(playerCoordinator)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)

        Settings {
            SettingsView()
                .frame(width: 480)
                .preferredColorScheme(.dark)
        }
        #endif
    }
}
