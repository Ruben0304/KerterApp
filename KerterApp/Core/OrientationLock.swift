#if os(iOS)
import UIKit

/// Permite forzar la rotación a horizontal al abrir el reproductor de video,
/// incluso si el usuario tiene el bloqueo de orientación activado (como hacen
/// Disney+, YouTube, etc. al entrar a pantalla completa).
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .all

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if canImport(GoogleCast)
        GoogleCastController.configure()
        #endif
        return true
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }
}

enum OrientationLock {
    /// Bloquea a horizontal y gira la pantalla, ignorando el interruptor de bloqueo de rotación.
    @MainActor
    static func lockLandscape() {
        AppDelegate.orientationLock = .landscape
        guard let scene = activeScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { _ in }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    /// Vuelve a permitir todas las orientaciones y regresa a vertical.
    @MainActor
    static func unlock() {
        AppDelegate.orientationLock = .all
        guard let scene = activeScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}

private extension UIWindowScene {
    var keyWindow: UIWindow? { windows.first { $0.isKeyWindow } }
}
#endif
