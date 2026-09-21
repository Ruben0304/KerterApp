import SwiftUI
import AVFoundation

/// Video sin controles para la vista previa del hero: silenciado, recortado
/// para llenar el marco y sin interacción (los clics pasan a la tarjeta).
#if os(macOS)
import AppKit

struct VideoPreview: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.attach(player)
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        view.attach(player)
    }
}

final class PlayerLayerView: NSView {
    private let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no soportado") }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func attach(_ player: AVPlayer) {
        if playerLayer.player !== player { playerLayer.player = player }
    }
}
#else
import UIKit

struct VideoPreview: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.attach(player)
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        view.attach(player)
    }
}

final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspectFill
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no soportado") }

    func attach(_ player: AVPlayer) {
        if playerLayer.player !== player { playerLayer.player = player }
    }
}
#endif
