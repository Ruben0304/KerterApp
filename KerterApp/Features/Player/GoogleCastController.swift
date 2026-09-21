#if os(iOS) && canImport(GoogleCast)
import Combine
import GoogleCast
import SwiftUI
import UIKit

/// Puente pequeño entre el reproductor de Kerter+ y el receptor Cast.
/// El televisor recibe la URL HLS del acelerador local, no la URL remota.
@MainActor
final class GoogleCastController: NSObject, ObservableObject {
    struct Media: Equatable {
        let url: URL
        let title: String
        let subtitle: String?
        let imageURL: URL?
        let isLive: Bool
    }

    static let shared = GoogleCastController()
    private static var configured = false

    @Published private(set) var isConnected = false
    @Published private(set) var isCasting = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var isMuted = false
    @Published private(set) var deviceName: String?
    @Published private(set) var errorMessage: String?

    private var preparedMedia: Media?
    private var loadedMedia: Media?
    private weak var remoteMediaClient: GCKRemoteMediaClient?

    /// Google exige crear el contexto Cast al arrancar la aplicación, antes
    /// de construir cualquier botón o abrir el selector de dispositivos.
    static func configure() {
        guard !configured else { return }
        configured = true

        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        options.physicalVolumeButtonsWillControlDeviceVolume = true
        options.stopReceiverApplicationWhenEndingSession = true
        GCKCastContext.setSharedInstanceWith(options)
        shared.attachToSessionManager()
    }

    func prepare(_ media: Media) {
        preparedMedia = media
        errorMessage = nil
        if isConnected { loadPreparedMediaIfNeeded() }
    }

    func togglePlayPause() {
        guard let client = remoteMediaClient else { return }
        if client.mediaStatus?.playerState == .playing {
            client.pause()
        } else {
            client.play()
        }
    }

    func goLive() {
        guard let client = remoteMediaClient else { return }
        let options = GCKMediaSeekOptions()
        options.seekToInfinite = true
        options.resumeState = .play
        client.seek(with: options)
    }

    func toggleMute() {
        guard let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession else { return }
        session.setDeviceMuted(!isMuted)
    }

    /// Se usa al cerrar el reproductor: el receptor deja de pedir segmentos
    /// antes de apagar el servidor HLS local.
    func endPlayback() {
        if isCasting { remoteMediaClient?.stop() }
        preparedMedia = nil
        loadedMedia = nil
        isCasting = false
        isPlaying = false
        isBuffering = false
        errorMessage = nil
    }

    private func attachToSessionManager() {
        let manager = GCKCastContext.sharedInstance().sessionManager
        manager.add(self)
        updateSession(manager.currentCastSession)
    }

    private func updateSession(_ session: GCKCastSession?) {
        if remoteMediaClient !== session?.remoteMediaClient {
            remoteMediaClient?.remove(self)
            remoteMediaClient = session?.remoteMediaClient
            remoteMediaClient?.add(self)
        }

        isConnected = session != nil
        deviceName = session?.device.friendlyName
        isMuted = session?.currentDeviceMuted ?? false
        if session == nil {
            loadedMedia = nil
            isCasting = false
            isPlaying = false
            isBuffering = false
        } else {
            updateMediaStatus(remoteMediaClient?.mediaStatus)
            loadPreparedMediaIfNeeded()
        }
    }

    private func loadPreparedMediaIfNeeded() {
        guard let media = preparedMedia,
              media != loadedMedia,
              let client = remoteMediaClient else { return }

        let metadata = GCKMediaMetadata(metadataType: .generic)
        metadata.setString(media.title, forKey: kGCKMetadataKeyTitle)
        if let subtitle = media.subtitle, !subtitle.isEmpty {
            metadata.setString(subtitle, forKey: kGCKMetadataKeySubtitle)
        }
        if let imageURL = media.imageURL {
            metadata.addImage(GCKImage(url: imageURL, width: 1280, height: 720))
        }

        let information = GCKMediaInformationBuilder(contentURL: media.url)
        information.contentType = "application/x-mpegURL"
        information.streamType = media.isLive ? .live : .buffered
        information.streamDuration = media.isLive ? .infinity : 0
        information.metadata = metadata

        let requestData = GCKMediaLoadRequestDataBuilder()
        requestData.mediaInformation = information.build()
        requestData.autoplay = NSNumber(value: true)
        let request = client.loadMedia(with: requestData.build())
        request.delegate = self

        loadedMedia = media
        isCasting = true
        isBuffering = true
        errorMessage = nil
    }

    private func updateMediaStatus(_ status: GCKMediaStatus?) {
        guard let status else {
            isPlaying = false
            isBuffering = isCasting
            return
        }
        switch status.playerState {
        case .playing:
            isCasting = true
            isPlaying = true
            isBuffering = false
        case .buffering, .loading:
            isCasting = true
            isPlaying = false
            isBuffering = true
        case .paused:
            isCasting = true
            isPlaying = false
            isBuffering = false
        case .idle, .unknown:
            isPlaying = false
            isBuffering = false
        @unknown default:
            isPlaying = false
            isBuffering = false
        }
    }
}

extension GoogleCastController: @preconcurrency GCKSessionManagerListener {
    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        updateSession(session)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didResumeCastSession session: GCKCastSession) {
        updateSession(session)
    }

    func sessionManager(_ sessionManager: GCKSessionManager,
                        didSuspend session: GCKCastSession,
                        with reason: GCKConnectionSuspendReason) {
        updateSession(nil)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, willEnd session: GCKCastSession) {
        updateSession(nil)
    }

    func sessionManager(_ sessionManager: GCKSessionManager,
                        didEnd session: GCKCastSession,
                        withError error: (any Error)?) {
        updateSession(sessionManager.currentCastSession)
    }

    func sessionManager(_ sessionManager: GCKSessionManager,
                        didFailToStart session: GCKSession,
                        withError error: any Error) {
        errorMessage = error.localizedDescription
        updateSession(sessionManager.currentCastSession)
    }

    func sessionManager(_ sessionManager: GCKSessionManager,
                        castSession session: GCKCastSession,
                        didReceiveDeviceVolume volume: Float,
                        muted: Bool) {
        isMuted = muted
    }
}

extension GoogleCastController: @preconcurrency GCKRemoteMediaClientListener {
    func remoteMediaClient(_ client: GCKRemoteMediaClient,
                           didUpdate mediaStatus: GCKMediaStatus?) {
        updateMediaStatus(mediaStatus)
    }
}

extension GoogleCastController: @preconcurrency GCKRequestDelegate {
    func requestDidComplete(_ request: GCKRequest) {
        errorMessage = nil
    }

    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        errorMessage = error.localizedDescription
        loadedMedia = nil
        isCasting = false
        isBuffering = false
    }

    func request(_ request: GCKRequest, didAbortWith abortReason: GCKRequestAbortReason) {
        loadedMedia = nil
        isCasting = false
        isBuffering = false
    }
}

/// Botón oficial: muestra disponibilidad, conexión y el selector nativo Cast.
struct GoogleCastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> GCKUICastButton {
        let button = GCKUICastButton(frame: .zero)
        button.tintColor = .white
        return button
    }

    func updateUIView(_ uiView: GCKUICastButton, context: Context) {
        uiView.tintColor = .white
    }
}
#endif
