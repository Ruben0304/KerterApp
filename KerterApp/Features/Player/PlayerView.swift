import SwiftUI
import AVKit
import os
#if os(iOS)
import AVFAudio
#endif

// MARK: - Calidades reales del stream

/// Una calidad que el stream HLS ofrece de verdad (leída de su playlist maestra).
struct StreamVariant: Identifiable, Hashable {
    let width: Int
    let height: Int
    let bitRate: Double      // bits por segundo

    var id: String { "\(height)-\(Int(bitRate))" }
    var label: String { "\(height)p" }
    var detail: String { String(format: "%.1f Mbps", bitRate / 1_000_000) }
    var badge: String? {
        switch height {
        case 2160...: return "4K"
        case 1080...: return "Full HD"
        case 720...: return "HD"
        default: return nil
        }
    }
}

enum QualityChoice: Hashable {
    case auto
    case variant(StreamVariant)
}

// MARK: - Línea de tiempo

/// Foto de la reproducción, refrescada dos veces por segundo.
struct TimelineState: Equatable {
    var start: Double = 0        // inicio de lo que el servidor guarda hacia atrás
    var end: Double = 0          // borde del directo (o duración, si no es directo)
    var current: Double = 0
    var loadedEnd: Double = 0    // hasta dónde hay descargado
    var isLive = false
    var isPlaying = false
    var isWaiting = false

    var window: Double { max(0, end - start) }
    /// El servidor permite moverse hacia atrás (ventana DVR).
    var hasWindow: Bool { window > 5 }
    var ahead: Double { max(0, loadedEnd - current) }
    var behindEdge: Double { max(0, end - current) }
}

// MARK: - Reproductor

struct PlayerView: View {
    let channel: Channel
    /// Retomar lo guardado de este canal donde lo dejaste (se elige en la
    /// ficha del partido); si no, en vivo.
    var resume = false
    let onClose: () -> Void

    @State private var player: AVPlayer?
    /// Vivos mientras dura la reproducción de un canal ClearKey: si se liberan,
    /// AVFoundation deja de poder resolver la clave.
    @State private var contentKeySession: AVContentKeySession?
    @State private var contentKeyDelegate: ClearKeyDelegate?
    #if canImport(VLCKit)
    @State private var vlcPlayer: VLCDASHPlayer?
    @State private var vlcIsPlaying = false
    @State private var vlcIsMuted = false
    #endif
    @State private var quality: QualityChoice = .auto
    @State private var variants: [StreamVariant] = []
    /// Lo que se está reproduciendo realmente ahora (no lo que se pidió).
    @State private var currentHeight: Int?
    @State private var showingQuality = false
    @State private var controlsVisible = true
    @State private var hideWork: DispatchWorkItem?
    @State private var unsupported: String?
    @State private var timeline = TimelineState()
    @State private var scrubFraction: Double?
    @State private var isMuted = false
    @State private var governor = BitrateGovernor()
    /// Tras un corte se pausa hasta juntar algo de buffer, en vez de encadenar
    /// microcortes reanudando con lo justo.
    @State private var rebufferingSince: Date?
    /// Última vez que creció lo descargado: sin avances, la señal está muerta.
    @State private var lastProgressAt = Date()
    @State private var stableSince: Date?
    @State private var reconnectAttempt = 0
    @State private var reconnectTask: Task<Void, Never>?
    @State private var networkAvailable = true
    /// Grabador local (canales HLS en directo): AVPlayer lee de él, no de internet.
    @State private var proxy: LiveProxy?
    @State private var proxyStatus: LiveProxy.Status?
    @State private var startTask: Task<Void, Never>?
    /// Fecha (en lo grabado) de lo último que se vio: para recolocar el video
    /// en el mismo punto si hay que recrear el item.
    @State private var lastPlayheadDate: Date?
    @State private var pendingSeekDate: Date?
    @State private var lastRebuildAt = Date.distantPast
    /// Al retomar, se arranca parado y se reproduce tras recolocar.
    @State private var playAfterSeek = false
    /// Arrancando parado hasta tener grabado el margen completo (ajuste).
    @State private var fillingMargin = false
    @State private var lastLoggedExternal = false
    #if os(iOS) && canImport(GoogleCast)
    @ObservedObject private var cast = GoogleCastController.shared
    @State private var resumeLocalAfterCast = false
    #endif
    @AppStorage(PlaybackSettings.bufferKey) private var bufferSeconds = PlaybackSettings.defaultBuffer
    @AppStorage(PlaybackSettings.proxyKey) private var proxyEnabled = PlaybackSettings.defaultProxy
    @AppStorage(PlaybackSettings.waitForMarginKey) private var waitForMargin = PlaybackSettings.defaultWaitForMargin
    #if os(macOS)
    @State private var window: NSWindow?
    @State private var isFullScreen = false
    @State private var closeAfterExitingFullScreen = false
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                PlatformPlayer(player: player)
                    .ignoresSafeArea()
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        #if os(macOS)
                        togglePlay()
                        #else
                        withAnimation(.easeInOut(duration: 0.25)) { controlsVisible.toggle() }
                        if controlsVisible { flashControls() }
                        #endif
                    }
            } else if hasActiveVLCPlayer {
                vlcPlayerContent
            } else if let reason = unsupported {
                unsupportedView(reason)
            } else if channel.streamURL == nil {
                unavailable
            } else {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large).tint(.white)
                    if proxyStatus?.sourceDown == true { sourceDownNotice }
                }
            }

            #if os(iOS) && canImport(GoogleCast)
            if cast.isConnected, player != nil { castDestinationOverlay }
            #endif

            controlsBar
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
                .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            start()
            flashControls()
            #if os(iOS)
            OrientationLock.lockLandscape()
            #endif
        }
        .onChange(of: quality) { _, _ in applyQuality() }
        .onChange(of: showingQuality) { _, open in
            if open { hideWork?.cancel() } else { flashControls() }
        }
        #if os(iOS) && canImport(GoogleCast)
        .onChange(of: cast.isConnected) { _, connected in castConnectionChanged(connected) }
        #endif
        .task(id: player.map(ObjectIdentifier.init)) { await trackPlayback() }
        .task {
            for await online in NetworkPath.updates() { networkChanged(online) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.playbackStalledNotification)) { note in
            guard let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
            handleStall()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification)) { note in
            guard let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
            recoverFromFailure()
        }
        #if os(macOS)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            togglePlay()
            return .handled
        }
        #endif
        .onDisappear {
            startTask?.cancel()
            #if os(iOS) && canImport(GoogleCast)
            cast.endPlayback()
            #endif
            // Lo grabado y dónde ibas se guardan para "Continuar viendo".
            proxy?.stop(saving: true)
            proxy = nil
            reconnectTask?.cancel()
            reconnectTask = nil
            player?.pause()
            player = nil
            contentKeySession = nil
            contentKeyDelegate = nil
            #if canImport(VLCKit)
            vlcPlayer?.stop()
            vlcPlayer = nil
            #endif
            hideWork?.cancel()
            #if os(iOS)
            OrientationLock.unlock()
            #else
            setWindowButtonsVisible(true)
            #endif
        }
        #if os(macOS)
        .background(WindowAccessor { found in
            guard let found, window !== found else { return }
            // Pantalla completa nativa: la ventana pasa a su propio escritorio.
            found.collectionBehavior.insert(.fullScreenPrimary)
            window = found
            isFullScreen = found.styleMask.contains(.fullScreen)
            setWindowButtonsVisible(controlsVisible)
        })
        .onChange(of: controlsVisible) { _, visible in setWindowButtonsVisible(visible) }
        .onContinuousHover { phase in
            if case .active = phase { flashControls() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            guard (note.object as? NSWindow) === window else { return }
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard (note.object as? NSWindow) === window else { return }
            isFullScreen = false
            if closeAfterExitingFullScreen {
                closeAfterExitingFullScreen = false
                onClose()
            }
        }
        .onExitCommand {
            if isFullScreen { window?.toggleFullScreen(nil) } else { close() }
        }
        #endif
    }

    // MARK: - Controles superpuestos

    private var controlsBar: some View {
        VStack {
            HStack(spacing: 12) {
                // En Mac cerrar y pantalla completa son los semáforos nativos
                // de la ventana (que aparecen y se esconden con estos controles).
                #if os(iOS)
                glassIcon("xmark", action: close)
                    .help("Cerrar")
                #endif

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    if channel.isLive {
                        Circle().fill(Theme.live).frame(width: 7, height: 7)
                    }
                    Text(channel.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: Capsule())

                Spacer(minLength: 12)

                if player != nil {
                    AirPlayButton(player: player, onPresenting: airPlayWillPresent, onDismissed: airPlayDidDismiss)
                        .frame(width: 22, height: 22)
                        .padding(11)
                        .glassEffect(.regular, in: Circle())
                        .help("AirPlay")
                    #if os(iOS) && canImport(GoogleCast)
                    if !channel.hasDRM {
                        GoogleCastButton()
                            .frame(width: 22, height: 22)
                            .padding(11)
                            .glassEffect(.regular, in: Circle())
                            .help("Google Cast")
                    }
                    #endif
                    qualityButton
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 30)
            .background(LinearGradient(colors: [.black.opacity(0.55), .clear],
                                       startPoint: .top, endPoint: .bottom))
            Spacer()
            if player != nil { bottomBar }
            #if canImport(VLCKit)
            if vlcPlayer != nil { vlcBottomBar }
            #endif
        }
    }

    #if canImport(VLCKit)
    /// Controles reducidos para DASH: libVLC no expone la misma telemetría de
    /// buffer/DVR que `AVPlayerItem`, así que aquí solo hay play/pause y mute.
    private var vlcBottomBar: some View {
        HStack(spacing: 10) {
            glassIcon(vlcIsPlaying ? "pause.fill" : "play.fill") {
                vlcPlayer?.togglePlay()
            }
            .help(vlcIsPlaying ? "Pausar" : "Reproducir")
            Spacer(minLength: 8)
            glassIcon(vlcIsMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                vlcIsMuted.toggle()
                vlcPlayer?.isMuted = vlcIsMuted
            }
            .help(vlcIsMuted ? "Activar sonido" : "Silenciar")
        }
        .padding(.horizontal, 18)
        .padding(.top, 40)
        .padding(.bottom, 16)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.65)],
                                   startPoint: .top, endPoint: .bottom))
    }
    #endif

    private var bottomBar: some View {
        Group {
            #if os(iOS) && canImport(GoogleCast)
            if cast.isConnected { castBottomBar } else { localBottomBar }
            #else
            localBottomBar
            #endif
        }
    }

    private var localBottomBar: some View {
        VStack(spacing: 12) {
            timelineBar
            HStack(spacing: 10) {
                glassIcon(timeline.isPlaying ? "pause.fill" : "play.fill", action: togglePlay)
                    .help(timeline.isPlaying ? "Pausar" : "Reproducir")
                liveButton
                if timeline.isWaiting || rebufferingSince != nil || reconnectTask != nil {
                    ProgressView().controlSize(.small).tint(.white)
                }
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                Spacer(minLength: 8)
                glassIcon(isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                    isMuted.toggle()
                    player?.isMuted = isMuted
                }
                .help(isMuted ? "Activar sonido" : "Silenciar")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 40)
        .padding(.bottom, 16)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.65)],
                                   startPoint: .top, endPoint: .bottom))
    }

    #if os(iOS) && canImport(GoogleCast)
    private var castBottomBar: some View {
        HStack(spacing: 10) {
            glassIcon(cast.isPlaying ? "pause.fill" : "play.fill") {
                cast.togglePlayPause()
                flashControls()
            }
            .help(cast.isPlaying ? "Pausar en el televisor" : "Reproducir en el televisor")

            if channel.isLive {
                Button {
                    cast.goLive()
                    flashControls()
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.live).frame(width: 8, height: 8)
                        Text("EN VIVO")
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .help("Ir al directo en el televisor")
            }

            if cast.isBuffering { ProgressView().controlSize(.small).tint(.white) }
            Text(cast.errorMessage ?? "Reproduciendo en \(cast.deviceName ?? "Google TV")")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(cast.errorMessage == nil ? .white.opacity(0.75) : Theme.live)
                .lineLimit(1)
            Spacer(minLength: 8)
            glassIcon(cast.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                cast.toggleMute()
                flashControls()
            }
            .help(cast.isMuted ? "Activar sonido del televisor" : "Silenciar televisor")
        }
        .padding(.horizontal, 18)
        .padding(.top, 40)
        .padding(.bottom, 16)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.65)],
                                   startPoint: .top, endPoint: .bottom))
    }

    private var castDestinationOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "tv.and.mediabox")
                .font(.system(size: 48, weight: .light))
            Text("Reproduciendo en \(cast.deviceName ?? "Google TV")")
                .font(.headline)
            if cast.isBuffering { ProgressView().tint(.white) }
            if let error = cast.errorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(Theme.live)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .foregroundStyle(.white)
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.88))
        .allowsHitTesting(false)
    }
    #endif

    /// Barra con lo reproducido (blanco), lo ya descargado (gris claro) y, en
    /// directo, una marca roja donde queda el margen configurado.
    private var timelineBar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let played = scrubFraction ?? playedFraction
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(.white.opacity(0.45))
                    .frame(width: max(0, w * bufferedFraction))
                Capsule().fill(.white)
                    .frame(width: max(0, w * played))
                if timeline.isLive, let target = targetFraction {
                    Capsule().fill(Theme.live)
                        .frame(width: 2, height: 11)
                        .offset(x: w * target - 1)
                }
                if timeline.hasWindow {
                    Circle().fill(.white)
                        .frame(width: 13, height: 13)
                        .shadow(color: .black.opacity(0.4), radius: 3)
                        .offset(x: w * played - 6.5)
                }
            }
            .frame(height: 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard timeline.hasWindow, w > 0 else { return }
                        scrubFraction = min(1, max(0, value.location.x / w))
                        hideWork?.cancel()
                    }
                    .onEnded { _ in
                        if let fraction = scrubFraction {
                            seek(to: timeline.start + fraction * timeline.window)
                        }
                        scrubFraction = nil
                        flashControls()
                    }
            )
        }
        .frame(height: 22)
        .animation(.linear(duration: 0.4), value: bufferedFraction)
    }

    private var playedFraction: Double {
        guard timeline.hasWindow else { return 0 }
        return min(1, max(0, (timeline.current - timeline.start) / timeline.window))
    }

    private var bufferedFraction: Double {
        if timeline.hasWindow {
            return min(1, max(0, (timeline.loadedEnd - timeline.start) / timeline.window))
        }
        // Sin ventana DVR: la barra muestra cuánto del margen está descargado.
        return min(1, ahead / Double(max(bufferSeconds, 1)))
    }

    private var targetFraction: Double? {
        guard timeline.hasWindow else { return nil }
        let target = timeline.end - Double(bufferSeconds)
        return min(1, max(0, (target - timeline.start) / timeline.window))
    }

    /// Ir por el margen configurado (±10 s) cuenta como "en vivo".
    private var atLive: Bool {
        !timeline.hasWindow || timeline.behindEdge <= Double(bufferSeconds) + 10
    }

    @ViewBuilder
    private var liveButton: some View {
        if timeline.isLive {
            Button(action: goLive) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(atLive ? Theme.live : Color.white.opacity(0.55))
                        .frame(width: 8, height: 8)
                    Text(atLive ? "EN VIVO"
                                : "−" + Self.clock(timeline.behindEdge - Double(bufferSeconds)))
                        .monospacedDigit()
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .help(atLive ? "Viendo el directo con \(PlaybackSettings.label(bufferSeconds)) de margen"
                         : "Volver al directo")
        }
    }

    private var statusText: String {
        if !networkAvailable, reconnectTask != nil || rebufferingSince != nil || timeline.isWaiting {
            return "Sin conexión · esperando red…"
        }
        if proxyStatus?.sourceDown == true {
            return "El canal no emite ahora (fallo en su origen) · esperando…"
        }
        if reconnectTask != nil {
            return "Reconectando…"
        }
        if rebufferingSince != nil {
            let progress = "\(Int(ahead.rounded())) de \(Int(rebufferGoal.rounded())) s"
            return fillingMargin ? "Preparando margen \(progress)" : "Cargando buffer \(progress)"
        }
        if timeline.isLive {
            var text = "Buffer \(Int(ahead.rounded())) s de \(bufferSeconds) s"
            if let rate = proxyStatus?.throughput {
                text += String(format: " · %.1f Mbps", rate / 1_000_000)
            }
            return text
        }
        guard timeline.end > 0 else { return "" }
        return "\(Self.clock(timeline.current)) / \(Self.clock(timeline.end))"
    }

    private static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private var qualityButton: some View {
        Button { showingQuality.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: "sparkles.tv")
                Text(qualityLabel)
                    .monospacedDigit()
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .popover(isPresented: $showingQuality, arrowEdge: qualityArrowEdge) {
            QualityPicker(variants: variants, selection: $quality, currentHeight: currentHeight) {
                showingQuality = false
            }
            .presentationCompactAdaptation(.popover)
        }
    }

    /// El botón vive pegado arriba: en iOS no hay sitio para que el popover
    /// se abra hacia arriba (queda cortado por el borde de la pantalla), así
    /// que se abre hacia abajo. En Mac sí cabe y queda mejor hacia arriba.
    private var qualityArrowEdge: Edge {
        #if os(iOS)
        .top
        #else
        .bottom
        #endif
    }

    private var qualityLabel: String {
        switch quality {
        case .auto:
            return currentHeight.map { "Auto · \($0)p" } ?? "Auto"
        case .variant(let variant):
            return variant.label
        }
    }

    private func glassIcon(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
    }

    private var hasActiveVLCPlayer: Bool {
        #if canImport(VLCKit)
        vlcPlayer != nil
        #else
        false
        #endif
    }

    @ViewBuilder
    private var vlcPlayerContent: some View {
        #if canImport(VLCKit)
        if let vlcPlayer {
            VLCPlayerSurface(player: vlcPlayer)
                .ignoresSafeArea()
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.25)) { controlsVisible.toggle() }
                    if controlsVisible { flashControls() }
                }
        }
        #else
        EmptyView()
        #endif
    }

    private var sourceDownNotice: some View {
        VStack(spacing: 6) {
            Text("El canal no está emitiendo ahora mismo")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Su señal de origen está caída (no es tu conexión). En cuanto vuelva, empieza solo.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
    }

    private var unavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: "tv.slash").font(.system(size: 44)).foregroundStyle(.white.opacity(0.7))
            Text("Sin señal reproducible").font(.headline).foregroundStyle(.white)
            Text("Este canal no expone una URL de stream reproducible.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center).frame(maxWidth: 320)
        }
        .padding()
    }

    private func unsupportedView(_ reason: String) -> some View {
        VStack(spacing: 14) {
            // OJO: "lock.tv" no existe como SF Symbol (era el
            // "No symbol named 'lock.tv'" del log); se usa uno válido.
            Image(systemName: "lock.fill")
                .font(.system(size: 46))
                .foregroundStyle(.white.opacity(0.75))
            Text(channel.name).font(.headline).foregroundStyle(.white)
            Text(reason)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding()
    }

    // MARK: - Lógica

    private func start() {
        configurePlaybackSession()
        guard let url = channel.streamURL else { return }
        #if DEBUG
        // Para pruebas de red fuera de la app (`log show --predicate 'subsystem == "KerterApp"'`).
        Logger(subsystem: "KerterApp", category: "player")
            .notice("stream \(channel.name, privacy: .public) [\(channel.playerType ?? "hls", privacy: .public)]: \(url.absoluteString, privacy: .public)")
        #endif

        if channel.isDASH {
            #if DEBUG
            ProxyLog.log("DASH drm: hasDRM=\(channel.hasDRM) kid=\(channel.drmKeyId.map { String($0.prefix(8)) + "…" } ?? "nil") keyLen=\(channel.drmKey?.count ?? 0)")
            #endif
            if channel.hasDRM {
                // DASH cifrado con ClearKey: se intenta con VLC pasándole la
                // KID/key del backend. OJO: las builds stock de VLCKit no
                // descifran CENC; si se queda en negro, el camino fiable es
                // que el backend re-sirva el canal como HLS (con EXT-X-KEY,
                // que sí cubrimos con ClearKeyDelegate).
                let kidOK = channel.drmKeyId.flatMap { DRMKeyFormat.data(from: $0) }?.count == 16
                let keyOK = channel.drmKey.flatMap { DRMKeyFormat.data(from: $0) }?.count == 16
                guard kidOK, keyOK else {
                    unsupported = "Este canal DASH viene cifrado pero el backend no mandó una clave válida (kid: \(channel.drmKeyId == nil ? "falta" : "inválida"), key: \(channel.drmKey == nil ? "falta" : "inválida"))."
                    return
                }
                #if canImport(VLCKit)
                let vp = VLCDASHPlayer(url: url, clearKeyId: channel.drmKeyId, clearKey: channel.drmKey)
                vlcPlayer = vp
                vp.play()
                Task { await trackVLCPlayback(vp, isEncrypted: true) }
                #else
                unsupported = "Este canal transmite en DASH cifrado con DRM: falta compilar con el reproductor VLC integrado."
                #endif
                return
            }
            #if canImport(VLCKit)
            let vp = VLCDASHPlayer(url: url)
            vlcPlayer = vp
            vp.play()
            Task { await trackVLCPlayback(vp, isEncrypted: false) }
            #else
            unsupported = "Este canal transmite en DASH, que AVPlayer (el reproductor nativo de Apple) no soporta. Falta compilar con el reproductor VLC integrado."
            #endif
            return
        }

        // HLS sin DRM: pasa por el grabador local (varias conexiones, margen
        // que no caduca). Si no se puede grabar, directo del servidor.
        guard proxyEnabled, !channel.hasDRM else { return startPlayer(url: url) }
        if resume, let saved = LiveProxy.savedSession(for: url) {
            continueWatching(saved)
        } else {
            startLive(url)
        }
    }

    /// Declara la reproducción como video de formato largo antes de crear el
    /// AVPlayer. Sin esta política iOS puede presentar receptores compatibles
    /// con video como una ruta de "solo audio".
    private func configurePlaybackSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
            try session.setActive(true)
            ProxyLog.log("AirPlay: sesión configurada como longFormVideo")
        } catch {
            ProxyLog.log("AirPlay: no se pudo configurar la sesión: \(error.localizedDescription)")
        }
        #endif
    }

    /// Directo desde cero (descarta lo guardado de este canal).
    private func startLive(_ url: URL) {
        startTask = Task {
            let started = await LiveProxy.start(source: url) { status in proxyStatus = status }
            guard !Task.isCancelled else {
                started?.stop()
                return
            }
            guard let started, let local = started.localURL else {
                proxyStatus = nil
                return startPlayer(url: url)
            }
            proxy = started
            startPlayer(url: local)
        }
    }

    /// Retoma lo guardado en el punto exacto donde lo dejaste; al acabarse lo
    /// guardado, sigue en vivo.
    private func continueWatching(_ saved: LiveProxy.SavedSession) {
        startTask = Task {
            let resumed = await LiveProxy.resume(saved) { status in proxyStatus = status }
            guard !Task.isCancelled else {
                resumed?.stop(saving: true)
                return
            }
            guard let resumed, let local = resumed.localURL else { return startLive(saved.source) }
            proxy = resumed
            pendingSeekDate = saved.playhead
            lastPlayheadDate = saved.playhead
            startPlayer(url: local, offset: max(saved.ahead, 1), resuming: true)
        }
    }

    private func startPlayer(url: URL, offset: Double? = nil, resuming: Bool = false) {
        guard let item = makeItem(url: url, offset: offset) else { return }
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = true
        p.isMuted = isMuted
        p.allowsExternalPlayback = true
        lastProgressAt = .now
        player = p
        #if os(iOS) && canImport(GoogleCast)
        prepareGoogleCast(url: url)
        if cast.isConnected {
            // El receptor toma el HLS del acelerador; el AVPlayer local queda
            // pausado para no duplicar tráfico, audio ni batería.
            resumeLocalAfterCast = !resuming && !(waitForMargin && proxy != nil)
            p.pause()
        } else {
            startLocalPlayer(p, resuming: resuming)
        }
        #else
        startLocalPlayer(p, resuming: resuming)
        #endif
        Task { await loadVariants(from: p) }
    }

    private func startLocalPlayer(_ player: AVPlayer, resuming: Bool) {
        if resuming {
            // Parado hasta estar en el punto donde ibas.
            playAfterSeek = true
            player.pause()
        } else if waitForMargin, proxy != nil {
            // Arranque con el margen completo: parado hasta tenerlo grabado.
            fillingMargin = true
            rebufferingSince = .now
            player.pause()
        } else {
            player.play()
        }
    }

    /// Item listo para reproducir, con el buffer configurado. Se usa al abrir y
    /// en cada reconexión (un item fallido no se puede reaprovechar).
    /// `offset`: a cuánto del final empieza (por defecto, el margen).
    private func makeItem(url: URL, offset: Double? = nil) -> AVPlayerItem? {
        let item: AVPlayerItem
        if channel.hasDRM {
            guard let delegate = ClearKeyDelegate(keyIdHex: channel.drmKeyId ?? "", keyHex: channel.drmKey ?? "") else {
                unsupported = "Este canal está protegido con DRM ClearKey, pero la clave que envía el servidor no es válida."
                return nil
            }
            let asset = AVURLAsset(url: url)
            let session = AVContentKeySession(keySystem: .clearKey)
            session.setDelegate(delegate, queue: .main)
            session.addContentKeyRecipient(asset)
            ProxyLog.log("ClearKey setup: url=\(url.absoluteString) kid=\(channel.drmKeyId ?? "nil") keyLen=\(channel.drmKey?.count ?? 0)")
            #if DEBUG
            // Volcado del EXT-X-KEY real que ve iOS: revela METHOD y KEYFORMAT,
            // que es lo que decide si la ContentKeySession se activa o no.
            Task.detached {
                if let text = try? String(contentsOf: url) {
                    for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("#EXT-X-KEY") {
                        ProxyLog.log("ClearKey manifest: \(line)")
                    }
                }
            }
            #endif
            // Se guardan en @State: si se liberan antes de tiempo, AVFoundation
            // deja de poder responder a la solicitud de clave.
            contentKeySession = session
            contentKeyDelegate = delegate
            item = AVPlayerItem(asset: asset)
        } else {
            item = AVPlayerItem(url: url)
        }
        // Descarga por delante hasta el margen configurado…
        item.preferredForwardBufferDuration = TimeInterval(bufferSeconds)
        // …y arranca el directo ese tiempo por detrás del borde, para que haya
        // algo que descargar por delante (lo de "delante" del directo real aún
        // no existe). Si el canal guarda menos, AVPlayer usa lo que haya.
        item.configuredTimeOffsetFromLive = CMTime(seconds: offset ?? Double(bufferSeconds), preferredTimescale: 600)
        // No re-saltar solo al margen: si pausas, al seguir continúas donde ibas.
        item.automaticallyPreservesTimeOffsetFromLive = false
        // En pausa se sigue descargando: pausar un rato sirve para juntar buffer.
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        return item
    }

    private func airPlayWillPresent() {
        ProxyLog.log("AirPlay: selector abierto")
    }

    private func airPlayDidDismiss() {
        ProxyLog.log("AirPlay: selector cerrado")
    }

    // MARK: - Estabilidad

    /// Lo que hay por delante de lo que se ve. Con grabador, lo grabado
    /// (AVPlayer solo carga hasta su propio tope); sin él, lo que AVPlayer
    /// lleva descargado.
    private var ahead: Double {
        if proxy != nil, let proxyStatus { return proxyStatus.bufferAhead }
        return timeline.ahead
    }

    /// Buffer que se junta tras un corte antes de seguir. En directo no puede
    /// haber más por delante que lo que se va por detrás del borde.
    private var rebufferGoal: Double {
        if fillingMargin { return Double(bufferSeconds) }
        // Con grabador lo grabado no caduca: se junta más, y cada corte deja
        // un colchón mayor para el siguiente.
        if proxy != nil { return min(30, Double(bufferSeconds) / 2) }
        var goal = min(20, Double(bufferSeconds) / 3)
        if timeline.isLive, timeline.hasWindow {
            goal = min(goal, max(3, timeline.behindEdge * 0.8))
        }
        return goal
    }

    /// El video se ha quedado sin buffer: pausa hasta tener `rebufferGoal`
    /// (sigue descargando) y baja un escalón de calidad si está en automática.
    private func handleStall() {
        guard let player, let item = player.currentItem,
              rebufferingSince == nil, reconnectTask == nil else { return }
        // Con margen de sobra grabado, el tirón es de AVPlayer (p. ej. al
        // cruzar un salto): basta con empujarlo, sin pausar.
        if proxy != nil, ahead >= rebufferGoal {
            player.playImmediately(atRate: 1)
            return
        }
        rebufferingSince = .now
        stableSince = nil
        player.pause()
        if quality == .auto, governor.noteStall(item) {
            item.preferredPeakBitRate = governor.cap ?? 0
        }
        flashControls()
    }

    /// Vigilancia de cada tick: reanudar tras juntar buffer, reconectar si la
    /// señal ha muerto y ajustar la calidad automática.
    private func supervise(_ player: AVPlayer, _ item: AVPlayerItem, previous: TimelineState, state: TimelineState) {
        let now = Date()
        if state.loadedEnd > previous.loadedEnd + 0.01 || state.isPlaying { lastProgressAt = now }
        if player.isExternalPlaybackActive != lastLoggedExternal {
            lastLoggedExternal = player.isExternalPlaybackActive
            ProxyLog.log("AirPlay: externalPlaybackActive=\(lastLoggedExternal) url=\(item.asset is AVURLAsset ? (item.asset as! AVURLAsset).url.absoluteString : "?")")
        }

        if let target = pendingSeekDate {
            // Item recreado: al estar listo, al mismo punto donde iba.
            if item.status == .readyToPlay {
                pendingSeekDate = nil
                _ = item.seek(to: target, completionHandler: nil)
                if playAfterSeek {
                    playAfterSeek = false
                    player.playImmediately(atRate: 1)
                }
            }
        } else {
            let date = item.currentDate()
            if let date { lastPlayheadDate = date }
            proxy?.reportPlayhead(date)
        }

        if item.status == .failed || player.status == .failed {
            recoverFromFailure()
            return
        }

        // Corte detectado por el cambio de estado (por si la notificación no llega).
        if previous.isPlaying, player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
           player.reasonForWaitingToPlay == .toMinimizeStalls {
            handleStall()
        }

        if let since = rebufferingSince {
            let waited = now.timeIntervalSince(since)
            let patience = fillingMargin ? Double(bufferSeconds) + 30 : 30
            if ahead >= rebufferGoal || (waited > patience && ahead >= 3) {
                rebufferingSince = nil
                fillingMargin = false
                // A la fuerza: el criterio propio de AVPlayer tras un corte
                // pide muchísimo más colchón del necesario.
                player.playImmediately(atRate: 1)
            }
        }

        // Esperando (o juntando buffer) sin que llegue nada: señal muerta.
        let stuck = rebufferingSince != nil || state.isWaiting
        if stuck, now.timeIntervalSince(lastProgressAt) > 20 {
            if let proxy {
                // AVPlayer lee de local: lo atascado es la conexión del grabador.
                proxy.kick()
                lastProgressAt = now
            } else {
                scheduleReconnect()
            }
        }

        // Medio minuto reproduciendo seguido: se reinicia la espera entre reintentos.
        if state.isPlaying {
            if stableSince == nil { stableSince = now }
            if let stableSince, now.timeIntervalSince(stableSince) > 30 { reconnectAttempt = 0 }
        } else {
            stableSince = nil
        }

        if governor.tick(item, now: now), quality == .auto {
            item.preferredPeakBitRate = governor.cap ?? 0
        }
    }

    /// Recrea la señal sin cerrar el reproductor, esperando cada vez más entre
    /// intentos (2, 4, 8, 16, 30 s). En directo vuelve con el margen configurado.
    private func scheduleReconnect(immediately: Bool = false) {
        guard player != nil, let url = channel.streamURL else { return }
        if immediately {
            reconnectTask?.cancel()
        } else if reconnectTask != nil {
            return
        }
        let delay = immediately ? 0 : min(30, 2 << min(reconnectAttempt, 4))
        reconnectAttempt += 1
        rebufferingSince = nil
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let current = player else { return }
            // Sin red no tiene sentido reintentar: se retoma al volver la conexión.
            guard networkAvailable else { return }
            let resumeAt = timeline.isLive ? nil : current.currentTime()
            guard let item = makeItem(url: url) else {
                reconnectTask = nil
                return
            }
            governor.resetMeasurements()
            if current.status == .failed {
                // Un AVPlayer fallido no se recupera: hace falta uno nuevo.
                let p = AVPlayer(playerItem: item)
                p.automaticallyWaitsToMinimizeStalling = true
                p.isMuted = isMuted
                player = p
            } else {
                current.replaceCurrentItem(with: item)
            }
            applyQuality()
            if let resumeAt, let player {
                await player.seek(to: resumeAt)
            }
            lastProgressAt = .now
            reconnectTask = nil
            player?.play()
        }
    }

    private func recoverFromFailure() {
        if proxy != nil { rebuildLocalItem() } else { scheduleReconnect() }
    }

    /// Con grabador, AVPlayer se rinde en un corte largo ("la playlist no
    /// cambia"), pero lo grabado sigue ahí: se recrea el item al momento y se
    /// recoloca en el punto exacto donde iba.
    private func rebuildLocalItem() {
        guard let current = player, let url = proxy?.localURL,
              Date().timeIntervalSince(lastRebuildAt) > 2,
              let item = makeItem(url: url, offset: max(ahead, 1)) else { return }
        lastRebuildAt = .now
        pendingSeekDate = lastPlayheadDate
        let target: AVPlayer
        if current.status == .failed {
            // Un AVPlayer fallido no se recupera: hace falta uno nuevo.
            target = AVPlayer(playerItem: item)
            target.automaticallyWaitsToMinimizeStalling = true
            target.isMuted = isMuted
            player = target
        } else {
            target = current
            current.replaceCurrentItem(with: item)
        }
        lastProgressAt = .now
        if ahead >= rebufferGoal {
            rebufferingSince = nil
            target.playImmediately(atRate: 1)
        } else {
            if rebufferingSince == nil { rebufferingSince = .now }
            target.pause()
        }
    }

    /// Al volver la red tras un corte, se reconecta sin esperar al siguiente
    /// reintento (solo si la reproducción estaba atascada).
    private func networkChanged(_ online: Bool) {
        let wasOffline = !networkAvailable
        networkAvailable = online
        if let proxy {
            // AVPlayer lee de local: es el grabador quien tiene que reconectar.
            // Solo al volver la red: macOS avisa también de cambios menores
            // (VPN, AirDrop…) y rehacer conexiones ahí cortaría descargas.
            if online, wasOffline { proxy.networkChanged(online: true) }
            return
        }
        guard online, wasOffline, let player else { return }
        let failed = player.status == .failed || player.currentItem?.status == .failed
        if failed || reconnectTask != nil || rebufferingSince != nil || timeline.isWaiting {
            reconnectAttempt = 0
            scheduleReconnect(immediately: true)
        }
    }

    private func close() {
        #if os(macOS)
        // Salir antes de la pantalla completa: cerrar una ventana que ocupa su
        // propio escritorio deja un espacio negro durante la animación.
        if isFullScreen, let window {
            closeAfterExitingFullScreen = true
            window.toggleFullScreen(nil)
            return
        }
        #endif
        onClose()
    }

    private func togglePlay() {
        guard let player else { return }
        if rebufferingSince != nil {
            // Tocar play mientras junta buffer: seguir ya con lo que haya.
            rebufferingSince = nil
            fillingMargin = false
            player.playImmediately(atRate: 1)
        } else if player.timeControlStatus == .paused {
            player.play()
        } else {
            player.pause()
        }
        flashControls()
    }

    #if os(iOS) && canImport(GoogleCast)
    private func prepareGoogleCast(url: URL) {
        guard !channel.hasDRM else { return }
        cast.prepare(.init(
            url: url,
            title: channel.name,
            subtitle: channel.subtitle ?? channel.category,
            imageURL: channel.heroImageURL ?? channel.posterURL ?? channel.logoURL,
            isLive: channel.isLive
        ))
    }

    private func castConnectionChanged(_ connected: Bool) {
        guard let player else { return }
        if connected {
            resumeLocalAfterCast = player.timeControlStatus != .paused
            player.pause()
        } else if resumeLocalAfterCast {
            resumeLocalAfterCast = false
            player.play()
        }
        flashControls()
    }
    #endif

    private func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero,
                     toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
    }

    /// Vuelve al directo, manteniendo el margen configurado.
    private func goLive() {
        if timeline.hasWindow {
            seek(to: max(timeline.start, timeline.end - Double(bufferSeconds)))
        }
        rebufferingSince = nil
        fillingMargin = false
        player?.play()
        flashControls()
    }

    #if os(macOS)
    /// Semáforos de la ventana al ritmo de los controles, como QuickTime.
    private func setWindowButtonsVisible(_ visible: Bool) {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window?.standardWindowButton($0) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            for button in buttons { button.animator().alphaValue = visible ? 1 : 0 }
        }
    }
    #endif

    /// Lee las calidades que ofrece de verdad la playlist maestra HLS. Muchos
    /// canales en directo emiten una sola: entonces no hay nada que elegir.
    private func loadVariants(from player: AVPlayer) async {
        if let proxy {
            // AVPlayer solo ve una calidad (la que graba el grabador): las
            // opciones son las del servidor.
            let list = proxy.variants.filter { $0.height > 0 }
                .map { StreamVariant(width: $0.width, height: $0.height, bitRate: $0.bandwidth) }
            let best = Dictionary(grouping: list, by: \.height)
                .compactMap { $0.value.max { $0.bitRate < $1.bitRate } }
                .sorted { $0.height > $1.height }
            variants = best.count > 1 ? best : []
            return
        }
        guard let asset = player.currentItem?.asset as? AVURLAsset,
              let all = try? await asset.load(.variants) else { return }

        let parsed: [StreamVariant] = all.compactMap { variant in
            guard let size = variant.videoAttributes?.presentationSize, size.height > 0 else { return nil }
            let bitRate = variant.peakBitRate ?? variant.averageBitRate ?? 0
            return StreamVariant(width: Int(size.width), height: Int(size.height), bitRate: bitRate)
        }
        // Una opción por resolución (la de más bitrate), de mayor a menor.
        let best = Dictionary(grouping: parsed, by: \.height)
            .compactMap { $0.value.max { $0.bitRate < $1.bitRate } }
            .sorted { $0.height > $1.height }
        variants = best.count > 1 ? best : []
        governor.setLadder(all.compactMap { variant in
            variant.videoAttributes == nil ? nil : variant.peakBitRate ?? variant.averageBitRate
        })
    }

    /// AVPlayer no puede forzar una calidad mínima: solo ponerle techo. Para
    /// "1080p" el techo es justo esa variante, así que reproduce la mejor que
    /// la conexión permita sin pasar de ahí.
    private func applyQuality() {
        if let proxy {
            switch quality {
            case .auto:
                proxy.setManualLevel(nil)
            case .variant(let variant):
                proxy.setManualLevel(proxy.variants.firstIndex {
                    $0.height == variant.height && $0.bandwidth == variant.bitRate
                })
            }
            return
        }
        guard let item = player?.currentItem else { return }
        switch quality {
        case .auto:
            item.preferredPeakBitRate = governor.cap ?? 0
            item.preferredMaximumResolution = .zero
        case .variant(let variant):
            item.preferredPeakBitRate = variant.bitRate * 1.1
            item.preferredMaximumResolution = CGSize(width: variant.width, height: variant.height)
        }
    }

    /// Resolución real, posición, ventana del directo y buffer descargado.
    private func trackPlayback() async {
        func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }

        while !Task.isCancelled {
            if let player, let item = player.currentItem {
                if item.presentationSize.height > 0 {
                    let value = Int(item.presentationSize.height.rounded())
                    if currentHeight != value { currentHeight = value }
                }

                var state = TimelineState()
                state.isLive = item.duration.isIndefinite
                let now = item.currentTime()
                state.current = finite(now.seconds)
                if let range = item.seekableTimeRanges.last?.timeRangeValue {
                    state.start = finite(range.start.seconds)
                    state.end = finite(range.end.seconds)
                } else if !state.isLive {
                    state.end = finite(item.duration.seconds)
                }
                let loaded = item.loadedTimeRanges.map(\.timeRangeValue)
                if let range = loaded.first(where: { $0.containsTime(now) }) ?? loaded.last {
                    state.loadedEnd = finite(range.end.seconds)
                }
                state.isPlaying = player.timeControlStatus == .playing
                state.isWaiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                let previous = timeline
                if state != timeline { timeline = state }
                supervise(player, item, previous: previous, state: state)
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    #if canImport(VLCKit)
    /// Sondeo simple del estado de reproducción para los canales DASH (VLC no
    /// nos da un stream de estado tipo KVO tan cómodo como `AVPlayerItem`).
    /// Si en ~20 s nunca llega a reproducir, se informa en vez de dejar la
    /// pantalla en negro: casi seguro la build de VLC no descifra CENC y hace
    /// falta que el backend lo re-sirva como HLS.
    private func trackVLCPlayback(_ vp: VLCDASHPlayer, isEncrypted: Bool) async {
        var ticks = 0
        var everPlaying = false
        while !Task.isCancelled, vlcPlayer != nil {
            let playing = vp.isPlaying
            vlcIsPlaying = playing
            everPlaying = everPlaying || playing
            ticks += 1
            if !everPlaying, ticks >= 40 {
                ProxyLog.log("VLC DASH: sin reproducir tras 20 s (cifrado=\(isEncrypted))")
                vp.stop()
                vlcPlayer = nil
                if isEncrypted {
                    unsupported = "VLC no pudo abrir este DASH cifrado (esta build no descifra CENC con ClearKey). Pide al backend una versión HLS del canal."
                } else {
                    unsupported = "VLC no pudo abrir este DASH (revisa la URL o la conexión)."
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
    #endif

    /// Muestra los controles y los oculta tras unos segundos sin actividad.
    private func flashControls() {
        controlsVisible = true
        hideWork?.cancel()
        guard !showingQuality else { return }
        let work = DispatchWorkItem {
            // En pausa o arrastrando la barra, los controles se quedan.
            #if os(iOS) && canImport(GoogleCast)
            let isPlaying = cast.isConnected ? cast.isPlaying : player?.timeControlStatus != .paused
            #else
            let isPlaying = player?.timeControlStatus != .paused
            #endif
            guard isPlaying, scrubFraction == nil else { return }
            withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}

// MARK: - Selector de calidad

struct QualityPicker: View {
    let variants: [StreamVariant]
    @Binding var selection: QualityChoice
    let currentHeight: Int?
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Calidad de video")
                    .font(.headline)
                Spacer()
                if let currentHeight {
                    Label("\(currentHeight)p", systemImage: "play.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .help("Resolución que se está reproduciendo ahora")
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 8)

            QualityRow(title: "Automática",
                       subtitle: "Se adapta a tu conexión",
                       badge: nil,
                       icon: "wand.and.stars",
                       isSelected: selection == .auto) {
                select(.auto)
            }

            if variants.isEmpty {
                Label("Este canal emite en una sola calidad", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                Divider().padding(.vertical, 4)
                ForEach(variants) { variant in
                    QualityRow(title: variant.label,
                               subtitle: variant.detail,
                               badge: variant.badge,
                               icon: nil,
                               isSelected: selection == .variant(variant)) {
                        select(.variant(variant))
                    }
                }
                Text("En directo el cambio tarda unos segundos: se aplica al llegar el siguiente fragmento.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            }
        }
        .padding(8)
        .frame(width: 300)
    }

    private func select(_ choice: QualityChoice) {
        withAnimation(.snappy) { selection = choice }
        onDone()
    }
}

private struct QualityRow: View {
    let title: String
    let subtitle: String
    let badge: String?
    let icon: String?
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Group {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 15, weight: .semibold))
                    } else {
                        Text(title)
                            .font(.system(size: 11, weight: .heavy))
                            .monospacedDigit()
                            .minimumScaleFactor(0.6)
                    }
                }
                .foregroundStyle(isSelected ? Color.black : Color.primary)
                .frame(width: 42, height: 30)
                .background(isSelected ? Color.white : Color.primary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(hovering ? Color.primary.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Reproductor nativo por plataforma
// Evitamos SwiftUI.VideoPlayer (crashea al instanciar metadata en este toolchain).

final class AirPlayCoordinator: NSObject, AVRoutePickerViewDelegate {
    let onPresenting: () -> Void
    let onDismissed: () -> Void
    init(_ onPresenting: @escaping () -> Void, _ onDismissed: @escaping () -> Void) {
        self.onPresenting = onPresenting
        self.onDismissed = onDismissed
    }
    func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) { onPresenting() }
    func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) { onDismissed() }
}

#if os(macOS)
import AppKit

/// Selector de rutas AirPlay nativo (el mismo del Centro de control).
struct AirPlayButton: NSViewRepresentable {
    let player: AVPlayer?
    let onPresenting: () -> Void
    let onDismissed: () -> Void
    func makeCoordinator() -> AirPlayCoordinator { AirPlayCoordinator(onPresenting, onDismissed) }
    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.delegate = context.coordinator
        v.isRoutePickerButtonBordered = false
        v.setRoutePickerButtonColor(.white, for: .normal)
        v.setRoutePickerButtonColor(.white, for: .active)
        v.player = player
        return v
    }
    func updateNSView(_ v: AVRoutePickerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

struct PlatformPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        // Controles propios (play, barra de buffer, EN VIVO…).
        view.controlsStyle = .none
        view.allowsPictureInPicturePlayback = true
        // Su "pantalla completa" interna no crea un escritorio propio: usamos la
        // de la ventana (botón de arriba o el verde del semáforo).
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        return view
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onWindow(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}

/// Coordina qué canal muestra la ventana dedicada del reproductor. Los
/// resúmenes de YouTube no pasan por aquí — se abren directo en la app de
/// YouTube, sin ventana propia.
@MainActor
final class PlayerCoordinator: ObservableObject {
    @Published var channel: Channel?
    /// "Continuar viendo" en vez de en vivo.
    var resume = false
}

/// Contenido de la ventana "Reproductor".
struct PlayerWindowHost: View {
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let channel = coordinator.channel {
                PlayerView(channel: channel, resume: coordinator.resume, onClose: {
                    coordinator.channel = nil
                    dismissWindow(id: "player")
                })
                .id(channel.id)
            }
        }
        .ignoresSafeArea()
        // Cerrar con el semáforo o ⌘W también cuenta como dejar de reproducir
        // (las vistas previas de la ventana principal esperan a esto).
        .onDisappear { coordinator.channel = nil }
    }
}
#else
import UIKit

/// Selector de rutas AirPlay nativo (el mismo del Centro de control).
struct AirPlayButton: UIViewRepresentable {
    let player: AVPlayer?
    let onPresenting: () -> Void
    let onDismissed: () -> Void
    func makeCoordinator() -> AirPlayCoordinator { AirPlayCoordinator(onPresenting, onDismissed) }
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.delegate = context.coordinator
        v.tintColor = .white
        v.activeTintColor = .white
        v.prioritizesVideoDevices = true
        return v
    }
    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}

struct PlatformPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = false
        vc.allowsPictureInPicturePlayback = true
        vc.videoGravity = .resizeAspect
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
    }
}
#endif
