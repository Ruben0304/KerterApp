#if canImport(VLCKit)
import SwiftUI
import VLCKit

/// Reproductor para los pocos canales que emiten en DASH (que `AVPlayer` no
/// entiende). Solo se usa para esos canales; todo lo demás sigue con
/// `AVPlayer` nativo. Controles reducidos a lo básico: libVLC no nos da la
/// misma telemetría de buffer/ventana DVR que `AVPlayerItem`, así que
/// `PlayerView` sondea `isPlaying` igual que hace con `trackPlayback()`.
@MainActor
final class VLCDASHPlayer {
    let mediaPlayer = VLCMediaPlayer()

    init(url: URL, clearKeyId: String? = nil, clearKey: String? = nil) {
        let media = VLCMedia(url: url)
        // Mejor esfuerzo: se le pasa la ClearKey al motor por si la build
        // de VLC sabe descifrar CENC (las builds stock la ignoran sin
        // romperse; los forks con descifrado CENC usan estas opciones).
        // Se registra en el log para diagnosticar si el backend mandó clave.
        if let kid = clearKeyId?.trimmingCharacters(in: .whitespacesAndNewlines),
           let key = clearKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !kid.isEmpty, !key.isEmpty {
            ProxyLog.log("VLC DASH: con ClearKey kid=\(kid.prefix(8))… keyLen=\(key.count)")
            media.addOption(":cenc-kid=\(kid)")
            media.addOption(":cenc-key=\(key)")
            media.addOption(":decryption-key=\(key)")
            media.addOption(":http-user-agent=AppleCoreMedia/1.0.0 KerterApp")
        } else {
            ProxyLog.log("VLC DASH: sin ClearKey (canal en abierto o sin clave del backend)")
        }
        mediaPlayer.media = media
    }

    var isPlaying: Bool { mediaPlayer.isPlaying }
    var isMuted: Bool {
        get { mediaPlayer.audio?.isMuted ?? false }
        set { mediaPlayer.audio?.isMuted = newValue }
    }

    func attach(to view: PlatformView) {
        mediaPlayer.drawable = view
    }

    func play() { mediaPlayer.play() }
    func stop() { mediaPlayer.stop() }

    func togglePlay() {
        if mediaPlayer.isPlaying {
            mediaPlayer.pause()
        } else {
            mediaPlayer.play()
        }
    }
}

#if os(macOS)
import AppKit
typealias PlatformView = NSView

struct VLCPlayerSurface: NSViewRepresentable {
    let player: VLCDASHPlayer
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        player.attach(to: view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#else
import UIKit
typealias PlatformView = UIView

struct VLCPlayerSurface: UIViewRepresentable {
    let player: VLCDASHPlayer
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        player.attach(to: view)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
#endif
