import SwiftUI
import AVFoundation

/// Ficha de un partido estilo Apple TV: portada grande con la señal en vivo de
/// fondo, datos del partido y el selector de canal (solo aquí se ven canales).
/// Si `item.isHighlightsOnly` (calendario o "Partidos recientes"), el selector
/// de canal se sustituye por el de resúmenes de YouTube y "Ver partido" se
/// convierte en "Ver resumen" — que no reproduce nada aquí dentro, solo abre
/// el video ya encontrado directamente en la app de YouTube.
struct EventDetailView: View {
    private enum LineupSide: Hashable { case home, away }

    let item: EventItem
    let resolve: (EventChannel) -> Channel?
    /// `resume`: "Continuar viendo" (retomar lo guardado) en vez de en vivo.
    let onPlay: (_ channel: Channel, _ resume: Bool) -> Void
    let onPlayHighlight: (YouTubeHighlightsService.Highlight) -> Void
    /// Con un canal reproduciéndose (o las vistas previas apagadas) la
    /// portada no abre su propia señal.
    var previewsPaused = false
    /// Stream que está en el reproductor ahora (para no ofrecer "Continuar"
    /// del mismo canal que ya se está viendo).
    var nowPlaying: URL?

    @Environment(\.dismiss) private var dismiss

    @State private var selectedID: Int?
    /// Lo guardado del canal elegido (visto antes): ofrece "Continuar viendo".
    @State private var saved: LiveProxy.SavedSession?
    @State private var preview: AVPlayer?
    @State private var previewTask: Task<Void, Never>?
    @State private var muted = true
    @State private var coverURL: URL?
    @State private var matchCenter: MatchCenterService.MatchCenter?
    @State private var highlightStates: [YouTubeHighlightsService.Source: YouTubeHighlightsService.LoadState] = [:]
    @State private var highlightLogos: [YouTubeHighlightsService.Source: URL] = [:]
    @State private var selectedHighlightSource: YouTubeHighlightsService.Source?
    @State private var selectedLineupSide: LineupSide = .home

    private var card: Channel { item.card }
    private var isHighlightsOnly: Bool { item.isHighlightsOnly }
    private var options: [EventChannel] { item.event.channels }
    private var selected: EventChannel? {
        options.first { $0.id == selectedID } ?? options.first
    }
    private var selectedChannel: Channel? { selected.flatMap(resolve) }
    private var hasCrests: Bool { card.homeLogoURL != nil || card.awayLogoURL != nil }
    private var showsScore: Bool { (card.isLive || card.isFinal) && card.homeScore != nil }

    private static let background = Color(hex: 0x0A0C10)

    #if os(macOS)
    private let titleSize: CGFloat = 46
    private let pad: CGFloat = 48
    #else
    private let titleSize: CGFloat = 32
    private let pad: CGFloat = 20
    #endif

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    header
                        .frame(height: max(440, geo.size.height * 0.78))
                    if isHighlightsOnly {
                        if !highlightSources.isEmpty { highlightsSection }
                    } else if !options.isEmpty {
                        channelPicker
                    }
                    if let center = matchCenter {
                        if center.hasStats { statsSection(center) }
                        if center.hasLineups { lineupsSection(center) }
                    }
                    if !isHighlightsOnly && !highlightSources.isEmpty { highlightsSection }
                    details
                }
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            #if os(iOS)
            .ignoresSafeArea(edges: .top)   // la portada llega hasta arriba
            #endif
        }
        .background(Self.background.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .onAppear {
            selectedID = item.event.previewOption(resolve: resolve)?.id
            selectedHighlightSource = highlightSources.first
            startPreview()
        }
        .onChange(of: selectedID) { _, _ in startPreview() }
        .onChange(of: previewsPaused) { _, paused in
            if paused { stopPreview() } else { startPreview() }
        }
        .onChange(of: muted) { _, value in preview?.isMuted = value }
        .onDisappear { stopPreview() }
        .task {
            if let url = card.heroImageURL {
                coverURL = url
                return
            }
            coverURL = await MatchArtService.cover(home: item.event.home, away: item.event.away)
        }
        .task { await loadMatchCenter() }
        .task { await loadHighlights() }
        #if os(macOS)
        .onExitCommand(perform: close)
        #endif
    }

    private func close() {
        stopPreview()
        dismiss()
    }

    /// LaLiga y Champions solamente — son las únicas ligas con resumen fiable.
    private var highlightSources: [YouTubeHighlightsService.Source] {
        guard card.isFinal else { return [] }
        return YouTubeHighlightsService.sources(forLeagueSlug: ESPNService.slug(forLeague: item.event.league))
    }

    private var selectedHighlight: YouTubeHighlightsService.Highlight? {
        guard let selectedHighlightSource,
              case .found(let highlight) = highlightStates[selectedHighlightSource] else { return nil }
        return highlight
    }

    /// Ninguna de las fuentes tiene resumen — solo entonces se dice, y una
    /// vez, no por fuente.
    private var noHighlightsAvailable: Bool {
        let sources = highlightSources
        guard !sources.isEmpty else { return false }
        return sources.allSatisfy {
            if case .found = highlightStates[$0] { return false }
            if case .loading = highlightStates[$0] { return false }
            return true
        }
    }

    private func loadHighlights() async {
        let sources = highlightSources
        guard !sources.isEmpty else { return }
        for source in sources { highlightStates[source] = .loading }
        await withTaskGroup(of: (YouTubeHighlightsService.Source, YouTubeHighlightsService.Highlight?).self) { group in
            for source in sources {
                group.addTask {
                    let highlight = await YouTubeHighlightsService.highlight(
                        for: source, home: item.event.home, away: item.event.away)
                    return (source, highlight)
                }
            }
            for await (source, highlight) in group {
                highlightStates[source] = highlight.map(YouTubeHighlightsService.LoadState.found) ?? .unavailable
            }
        }
        await withTaskGroup(of: (YouTubeHighlightsService.Source, URL?).self) { group in
            for source in sources where highlightLogos[source] == nil {
                group.addTask { (source, await YouTubeHighlightsService.logo(for: source)) }
            }
            for await (source, logo) in group {
                if let logo { highlightLogos[source] = logo }
            }
        }
    }

    // MARK: - Portada

    private var header: some View {
        Color.clear
            .overlay {
                ZStack {
                    backdrop
                    videoOverlay
                }
                .animation(.easeInOut(duration: 0.6), value: preview != nil)
                .animation(.easeInOut(duration: 0.6), value: selectedHighlight != nil)
                .heroParallax()
            }
            .overlay {
                ZStack {
                    LinearGradient(colors: [.black.opacity(0.6), .clear],
                                   startPoint: .top, endPoint: .init(x: 0.5, y: 0.25))
                    LinearGradient(colors: [.black.opacity(0.8), .black.opacity(0.2), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                    // Funde la portada con el fondo de la ficha, como Apple TV.
                    LinearGradient(stops: [.init(color: .clear, location: 0.4),
                                           .init(color: Self.background, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .overlay(alignment: .bottomLeading) { headerContent }
            .clipped()
    }

    @ViewBuilder
    private var videoOverlay: some View {
        if isHighlightsOnly {
            // Nunca se reproduce el resumen dentro de la app (YouTube no lo
            // permite de forma fiable para todas las fuentes) — la portada
            // solo enseña su miniatura, a todo lo alto y ancho como el
            // preview en vivo de un canal.
            if let thumbnail = selectedHighlight?.thumbnail {
                CachedImage(url: thumbnail, contentMode: .fill, placeholder: .clear)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        } else if let preview {
            VideoPreview(player: preview)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var backdrop: some View {
        if let coverURL {
            // Portada oficial del partido.
            Color.black
                .overlay {
                    CachedImage(url: coverURL, contentMode: .fill,
                                placeholder: .clear)
                }
                .clipped()
        } else {
            ZStack {
                Color.clear
                    .overlay {
                        Image((card.subtitle ?? "").localizedCaseInsensitiveContains("champions")
                              ? "HeroBGChampions" : "HeroBGDefault")
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                    .clipped()
                // Tinte con los colores de cada equipo.
                LinearGradient(colors: [(Color(hexString: card.homeColor) ?? .clear).opacity(0.4),
                                        (Color(hexString: card.awayColor) ?? .clear).opacity(0.4)],
                               startPoint: .leading, endPoint: .trailing)
            }
        }
    }

    private var headerContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                if card.isLive {
                    LiveBadge()
                } else if let pill = card.statusPill ?? card.startText, !pill.isEmpty {
                    Text(pill)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                if let league = card.subtitle, !league.isEmpty {
                    Text(league.uppercased())
                        .font(.caption.weight(.semibold))
                        .tracking(1)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }

            if hasCrests { crests }

            Text(card.name)
                .font(.system(size: titleSize, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .shadow(color: .black.opacity(0.4), radius: 10, y: 3)

            if !metaLine.isEmpty {
                Text(metaLine)
                    .font(.headline.weight(.regular))
                    .foregroundStyle(.white.opacity(0.7))
            }

            HStack(spacing: 12) {
                if showsPlayButton {
                    if highlightFirst {
                        highlightPlayButton
                        if selectedChannel != nil { channelSecondaryButton }
                    } else {
                        if let saved { continueButton(saved) }
                        playButton
                    }
                }
                if !isHighlightsOnly && preview != nil {
                    glassButton(muted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                        muted.toggle()
                    }
                }
            }
            .padding(.top, 4)
            .task(id: "\(selectedID ?? -1)|\(nowPlaying?.absoluteString ?? "")") { loadSaved() }

            if showsPlayButton, let saved {
                Text("Lo dejaste \(Self.ago(saved.savedAt)) · retoma donde ibas y luego sigue en vivo")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .padding(.horizontal, pad)
        .padding(.bottom, 24)
    }

    private var crests: some View {
        HStack(spacing: 20) {
            crest(card.homeLogoURL)
            if showsScore {
                Text("\(card.homeScore ?? "0")  –  \(card.awayScore ?? "0")")
                    .font(.system(size: 34, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            } else {
                Text("VS")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.7))
            }
            crest(card.awayLogoURL)
        }
    }

    private func crest(_ url: URL?) -> some View {
        CachedImage(url: url, contentMode: .fit, placeholder: .clear)
            .frame(width: 76, height: 76)
            .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
    }

    private var metaLine: String {
        [card.dateLabel, item.event.time ?? card.startText, card.category]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// En modo resumen, sin fuentes no hay nada que el botón pueda ofrecer.
    private var showsPlayButton: Bool { !isHighlightsOnly || !highlightSources.isEmpty }

    private var playButtonLabel: String {
        if isHighlightsOnly { return "Ver resumen" }
        if saved != nil { return "Ver en vivo" }
        return selected.map { "Ver en \($0.name)" } ?? "Ver partido"
    }

    /// Visto antes (más de 20 s) y guardado, y no es lo que ya está sonando.
    private func loadSaved() {
        guard !isHighlightsOnly, let url = selectedChannel?.streamURL, url != nowPlaying,
              let session = LiveProxy.savedSession(for: url), session.watched >= 20 else {
            saved = nil
            return
        }
        saved = session
    }

    private func continueButton(_ saved: LiveProxy.SavedSession) -> some View {
        Button {
            guard let channel = selectedChannel else { return }
            stopPreview()
            onPlay(channel, true)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text("Continuar viendo")
            }
            .font(.headline)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .buttonStyle(.glassProminent)
        .tint(.white)
        .foregroundStyle(.black)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }

    private static func ago(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        switch minutes {
        case ..<1: return "hace un momento"
        case 1: return "hace 1 minuto"
        case ..<60: return "hace \(minutes) minutos"
        default: return "hace \(minutes / 60) h \(minutes % 60) min"
        }
    }

    /// Partido ya terminado (según ESPN) con resumen posible: "Ver resumen" es
    /// lo principal y el canal pasa a secundario. Si ninguna fuente tiene
    /// resumen, vuelve a mandar "Ver partido".
    private var highlightFirst: Bool {
        !isHighlightsOnly && card.isFinal && !highlightSources.isEmpty && !noHighlightsAvailable
    }

    /// El de la fuente elegida o, si esa no lo tiene, el primero que exista.
    private var primaryHighlight: YouTubeHighlightsService.Highlight? {
        selectedHighlight ?? highlightSources.lazy.compactMap { source -> YouTubeHighlightsService.Highlight? in
            if case .found(let h) = highlightStates[source] { return h }
            return nil
        }.first
    }

    private var highlightPlayButton: some View {
        Button {
            guard let highlight = primaryHighlight else { return }
            stopPreview()
            onPlayHighlight(highlight)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text("Ver resumen")
            }
            .font(.headline)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .buttonStyle(.glassProminent)
        .tint(.white)
        .foregroundStyle(.black)
        .controlSize(.large)
        .disabled(primaryHighlight == nil)
        .keyboardShortcut(.defaultAction)
    }

    private var channelSecondaryButton: some View {
        Button {
            guard let channel = selectedChannel else { return }
            stopPreview()
            onPlay(channel, false)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "tv")
                Text(selected.map { "Ver en \($0.name)" } ?? "Ver canal")
            }
            .font(.headline)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .buttonStyle(.glass)
        .foregroundStyle(.white)
        .controlSize(.large)
    }

    private var playButton: some View {
        Button {
            if isHighlightsOnly {
                guard let selectedHighlight else { return }
                onPlayHighlight(selectedHighlight)
            } else {
                guard let channel = selectedChannel else { return }
                stopPreview()
                onPlay(channel, false)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: saved == nil ? "play.fill" : "dot.radiowaves.left.and.right")
                Text(playButtonLabel)
            }
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        }
        .buttonStyle(.glassProminent)
        .tint(saved == nil ? .white : .white.opacity(0.18))
        .foregroundStyle(saved == nil ? .black : .white)
        .controlSize(.large)
        .disabled(isHighlightsOnly ? selectedHighlight == nil : selectedChannel == nil)
        .keyboardShortcut(saved == nil ? .defaultAction : nil)
    }

    // MARK: - Selector de canal

    private var channelPicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Dónde ver")
                    .font(.title3.weight(.bold))
                Spacer()
                // Selector nativo del sistema (menú), además de las tarjetas.
                Picker("Canal", selection: Binding(
                    get: { selected?.id ?? Int.min },
                    set: { selectedID = $0 }
                )) {
                    ForEach(options) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, pad)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(options) { option in
                        ChannelOptionCard(option: option,
                                          isSelected: option.id == selected?.id,
                                          isAvailable: resolve(option) != nil) {
                            withAnimation(.snappy) { selectedID = option.id }
                        }
                    }
                }
                .padding(.horizontal, pad)
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Centro del partido (estadísticas y alineaciones)

    private var homeName: String { item.event.home.isEmpty ? "Local" : item.event.home }
    private var awayName: String { item.event.away.isEmpty ? "Visitante" : item.event.away }

    /// Colores de marca de los dos equipos, ya separados entre sí: muchos
    /// clubes se declaran en blanco, y dos barras blancas no dirían nada.
    private var teamColors: (home: Color, away: Color) {
        let fallback = (Color(hex: 0x3B82F6), Color(hex: 0xF97316))
        guard let h = Color(hexString: card.homeColor), let a = Color(hexString: card.awayColor),
              h.isDistinct(from: a) else { return fallback }
        return (h, a)
    }

    /// Se recarga sola mientras el partido está en juego: las estadísticas y
    /// las notas cambian cada pocos minutos.
    private func loadMatchCenter() async {
        while !Task.isCancelled {
            if let center = await MatchCenterService.load(home: item.event.home,
                                                          away: item.event.away,
                                                          league: item.event.league) {
                matchCenter = center
            } else if matchCenter == nil,
                      let lineups = await ESPNService.matchDetails(home: item.event.home,
                                                                   away: item.event.away,
                                                                   league: item.event.league)?.lineups {
                matchCenter = MatchCenterService.fallback(lineups)
            }
            // Manda lo que diga el propio partido; si todavía no hay datos,
            // vale la marca de la cartelera para seguir intentándolo.
            guard matchCenter?.isLive ?? card.isLive else { return }
            try? await Task.sleep(for: .seconds(35))
        }
    }

    private func statsSection(_ center: MatchCenterService.MatchCenter) -> some View {
        let colors = teamColors
        return VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Estadísticas", live: center.isLive)

            HStack(spacing: 10) {
                statsLegend(name: homeName, logo: card.homeLogoURL, color: colors.home, trailing: false)
                Spacer(minLength: 12)
                statsLegend(name: awayName, logo: card.awayLogoURL, color: colors.away, trailing: true)
            }
            .padding(.horizontal, pad)

            MatchStatsView(stats: center.stats, homeColor: colors.home, awayColor: colors.away)
                .padding(.horizontal, pad)
        }
    }

    private func statsLegend(name: String, logo: URL?, color: Color, trailing: Bool) -> some View {
        HStack(spacing: 7) {
            if trailing { Spacer(minLength: 0) }
            CachedImage(url: logo, contentMode: .fit, placeholder: .clear)
                .frame(width: 20, height: 20)
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            if !trailing { Spacer(minLength: 0) }
        }
    }

    private func lineupsSection(_ center: MatchCenterService.MatchCenter) -> some View {
        let colors = teamColors
        return VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Alineaciones", live: false)

            if let home = center.home, let away = center.away {
                VStack(spacing: 18) {
                    Picker("Equipo", selection: $selectedLineupSide) {
                        Text(homeName).tag(LineupSide.home)
                        Text(awayName).tag(LineupSide.away)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    let selectedTeam = selectedLineupSide == .home ? home : away
                    let selectedName = selectedLineupSide == .home ? homeName : awayName
                    let selectedLogo = selectedLineupSide == .home ? card.homeLogoURL : card.awayLogoURL
                    let selectedColor = selectedLineupSide == .home ? colors.home : colors.away

                    teamHeader(name: selectedName, logo: selectedLogo,
                               formation: selectedTeam.formation, color: selectedColor)

                    LineupPitchView(team: selectedTeam, teamColor: selectedColor)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)

                    benchBlock(team: selectedTeam)
                }
                .padding(.horizontal, pad)
            }
        }
    }

    private func sectionTitle(_ text: String, live: Bool) -> some View {
        HStack(spacing: 8) {
            Text(text).font(.title3.weight(.bold))
            if live {
                Text("EN VIVO")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2.5)
                    .background(Theme.live, in: Capsule())
            }
        }
        .padding(.horizontal, pad)
    }

    private func teamHeader(name: String, logo: URL?, formation: String?, color: Color) -> some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(color)
                .frame(width: 3, height: 18)
            CachedImage(url: logo, contentMode: .fit, placeholder: .clear)
                .frame(width: 22, height: 22)
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let formation, !formation.isEmpty {
                Text(formation)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.white.opacity(0.09), in: Capsule())
            }
            Spacer()
        }
    }

    private func benchBlock(team: MatchCenterService.TeamLineup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Suplentes")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                if let coach = team.coach {
                    Text("DT · \(coach)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }

            if team.bench.isEmpty {
                Text("No hay suplentes disponibles")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 0)], spacing: 0) {
                    ForEach(team.bench) { player in
                        Text(player.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 11)
                            .padding(.horizontal, 12)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
                            }
                    }
                }
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    // MARK: - Resúmenes (YouTube)

    /// Mismo diseño que "Dónde ver": una fila de tarjetas con el logo de cada
    /// fuente, tal cual salen los canales de un partido en vivo. Ambas
    /// fuentes a la vez —no una sola—; si una en concreto no tiene resumen
    /// todavía no se dice nada, solo queda sin marcar como disponible. El
    /// aviso "no hay resumen" es único, y solo cuando ninguna de las dos tiene.
    private var highlightsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Resúmenes")
                .font(.title3.weight(.bold))
                .padding(.horizontal, pad)

            if noHighlightsAvailable {
                Text("No hay resumen disponible")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, pad)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(highlightSources, id: \.self) { source in
                            HighlightOptionCard(
                                source: source,
                                logo: highlightLogos[source],
                                isSelected: source == selectedHighlightSource,
                                isAvailable: isFound(source)
                            ) {
                                withAnimation(.snappy) { selectedHighlightSource = source }
                            }
                        }
                    }
                    .padding(.horizontal, pad)
                    .padding(.vertical, 8)
                }

                // En modo normal no hay hueco de portada para el resumen —se
                // reproduce directo, como "Ver partido" en la portada arriba.
                if !isHighlightsOnly {
                    Button {
                        if let selectedHighlight { onPlayHighlight(selectedHighlight) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                            Text("Ver resumen")
                        }
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .controlSize(.large)
                    .disabled(selectedHighlight == nil)
                    .padding(.horizontal, pad)
                }
            }
        }
    }

    private func isFound(_ source: YouTubeHighlightsService.Source) -> Bool {
        if case .found = highlightStates[source] { return true }
        return false
    }

    // MARK: - Información

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Información")
                .font(.title3.weight(.bold))
            Grid(alignment: .leading, horizontalSpacing: 40, verticalSpacing: 12) {
                infoRow("Competición", card.subtitle)
                infoRow("Deporte", card.category)
                infoRow("Fecha", card.dateLabel)
                infoRow("Hora", item.event.time ?? card.startText)
                infoRow("Estado", card.isLive ? "En vivo" : (card.isFinal ? "Final" : "Por jugar"))
                infoRow("Estadio", card.venue)
                infoRow("Canales", options.isEmpty ? nil : "\(options.count) disponibles")
            }
        }
        .padding(.horizontal, pad)
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value).foregroundStyle(.primary)
            }
            .font(.subheadline)
        }
    }

    private func glassButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
    }

    // MARK: - Autoplay

    private func startPreview() {
        stopPreview()
        guard !previewsPaused, !isHighlightsOnly, let channel = selectedChannel, channel.canPreview,
              let url = channel.streamURL else { return }
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            let player = AVPlayer(url: url)
            player.isMuted = muted
            await MainActor.run {
                guard !Task.isCancelled else { return }
                preview = player
                player.play()
            }
        }
    }

    private func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        preview?.pause()
        preview = nil
    }
}

// MARK: - Opción de canal

struct ChannelOptionCard: View {
    let option: EventChannel
    let isSelected: Bool
    let isAvailable: Bool
    let action: () -> Void
    @State private var hovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Group {
                    if option.logo != nil {
                        CachedImage(url: option.logo, contentMode: .fit,
                                    placeholder: .clear)
                    } else {
                        Image(systemName: "tv")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .frame(width: 56, height: 40)

                Text(option.name)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if !isAvailable {
                    Text("No disponible")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 150, height: 110)
            .background(.white.opacity(isSelected ? 0.14 : 0.06), in: shape)
            .overlay(
                shape.strokeBorder(isSelected ? Color.white : Color.white.opacity(hovering ? 0.25 : 0.1),
                                   lineWidth: isSelected ? 2 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, .white)
                        .padding(8)
                }
            }
            .scaleEffect(hovering ? 1.03 : 1)
            .opacity(isAvailable ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - Tarjeta de fuente de resumen (YouTube)

/// Mismo aspecto que `ChannelOptionCard` (la de los canales en un partido en
/// vivo): logo, nombre, aro de selección. Sin texto de "no disponible" por
/// fuente — solo se atenúa, como los canales que no se pueden reproducir.
struct HighlightOptionCard: View {
    let source: YouTubeHighlightsService.Source
    let logo: URL?
    let isSelected: Bool
    let isAvailable: Bool
    let action: () -> Void
    @State private var hovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Group {
                    if let logo {
                        CachedImage(url: logo, contentMode: .fit, placeholder: .clear)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .frame(width: 40, height: 40)

                Text(source.rawValue)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(width: 150, height: 110)
            .background(.white.opacity(isSelected ? 0.14 : 0.06), in: shape)
            .overlay(
                shape.strokeBorder(isSelected ? Color.white : Color.white.opacity(hovering ? 0.25 : 0.1),
                                   lineWidth: isSelected ? 2 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, .white)
                        .padding(8)
                }
            }
            .scaleEffect(hovering ? 1.03 : 1)
            .opacity(isAvailable ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - Tarjeta de jugador (banquillo)

/// Suplente: retrato, dorsal, nota si ya jugó y el minuto en que entró.
struct LineupPlayerCard: View {
    let player: MatchCenterService.Player
    let accent: Color

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                ZStack(alignment: .bottomTrailing) {
                    CachedImage(url: player.photo, contentMode: .fill, placeholder: .clear)
                        .frame(width: 64, height: 64)
                        .background(
                            Circle().fill(
                                LinearGradient(colors: [accent.opacity(0.9), accent.opacity(0.5)],
                                               startPoint: .top, endPoint: .bottom))
                        )
                        .overlay {
                            if player.photo == nil, let jersey = player.jersey {
                                Text(jersey)
                                    .font(.system(size: 22, weight: .heavy))
                                    .monospacedDigit()
                                    .foregroundStyle(accent.isLight ? .black : .white)
                            }
                        }
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(accent.opacity(0.75), lineWidth: 1.5))

                    if let minute = player.subbedIn {
                        Text("\(minute)'")
                            .font(.system(size: 9, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1.5)
                            .background(Color(hex: 0x2FA84F), in: Capsule())
                            .overlay(Capsule().strokeBorder(.black.opacity(0.3), lineWidth: 0.75))
                    }
                }

                if let rating = player.rating {
                    RatingChip(rating: rating).offset(x: 5, y: -3)
                }
            }
            .frame(width: 68, height: 68)

            VStack(spacing: 2) {
                Text(player.shortName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let position = player.position, !position.isEmpty {
                    Text(position)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
        }
        .frame(width: 84)
    }
}
