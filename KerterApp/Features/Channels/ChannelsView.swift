import SwiftUI
import AVFoundation

/// Secciones de la barra lateral.
enum AppSection: String, Hashable, Identifiable {
    case search, home, live, replays, channels, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: return "Buscar"
        case .home: return "Inicio"
        case .live: return "En vivo"
        case .replays: return "Repeticiones"
        case .channels: return "Canales"
        case .settings: return "Ajustes"
        }
    }

    var icon: String {
        switch self {
        case .search: return "magnifyingglass"
        case .home: return "house"
        case .live: return "dot.radiowaves.left.and.right"
        case .replays: return "clock.arrow.circlepath"
        case .channels: return "tv"
        case .settings: return "gearshape"
        }
    }
}

/// Qué equipos lista el riel "Equipos" de Inicio.
enum TeamsMode: String, CaseIterable, Identifiable {
    case clubs, countries

    var id: String { rawValue }
    var title: String { self == .clubs ? "Clubes" : "Países" }
}

/// Pantallas que se abren empujadas en la pila de navegación (en vez de
/// dentro de la barra lateral): así el sistema pone su propia barra y el
/// botón "Atrás" nativo —cristal líquido de macOS 26 / iOS 26 incluido— sin
/// que tengamos que dibujar nada a mano.
enum LeagueDestination: Hashable {
    case competition(Competition)   // Partidos/Tabla/Calendario de una competición ("Competiciones")
    case extra                      // pantalla "Más" (5º item de la pastilla en iPhone)
}

struct MainView: View {
    @AppStorage(SportsFilterSettings.key) private var enabledSportsRaw = SportsFilterSettings.defaultRaw
    @StateObject private var vm: ChannelsViewModel

    @State private var section: AppSection? = .home
    /// Pantalla de cuadrícula filtrada por canal desde la barra de arriba.
    @State private var matchFilter: MatchFilter?
    /// Pila de navegación real de iPhone para las pantallas de liga.
    @State private var leaguePath = NavigationPath()
    /// Pila de navegación real de iPad/Mac para abrir una competición
    /// (Partidos/Tabla/Calendario) como pantalla empujada.
    @State private var competitionPath = NavigationPath()
    @State private var selectedCategory: String?   // nil = Todos (pantalla Canales)
    /// Fichas de partido abiertas en la pila: con alguna encima, el hero de
    /// Inicio no abre su vista previa.
    @State private var openEventCount = 0
    @State private var playing: Channel?
    @State private var playResume = false
    @AppStorage(PlaybackSettings.previewsKey) private var previewsEnabled = PlaybackSettings.defaultPreviews
    /// Grandes equipos del riel "Equipos" de Inicio (Barça, Madrid, Bayern…).
    @State private var bigClubTeams: [ESPNService.FeaturedTeam] = []
    /// Selecciones del mismo riel: las primeras del ranking FIFA y Cuba.
    @State private var countryTeams: [ESPNService.FeaturedTeam] = []
    /// Qué muestra el riel "Equipos": clubes o selecciones. Se recuerda entre sesiones.
    @AppStorage("home.teamsMode") private var teamsModeRaw = TeamsMode.clubs.rawValue
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    #if os(macOS)
    @EnvironmentObject private var playerCoordinator: PlayerCoordinator
    @Environment(\.openWindow) private var openWindow
    #endif

    init(auth: AuthManager) {
        _vm = StateObject(wrappedValue: ChannelsViewModel(auth: auth))
    }

    private var hPad: CGFloat { isCompact ? 16 : 32 }

    private func heroHeight(_ available: CGFloat) -> CGFloat {
        #if os(iOS)
        // Más alto que en Mac: el vídeo se recorta más, pero el parallax pide más scroll.
        return isCompact ? max(540, available * 0.86) : max(560, available * 0.82)
        #else
        return max(480, available * 0.74)
        #endif
    }

    // Barra lateral nativa (como la app de Apple TV) y el contenido a la
    // derecha. La ficha de un partido se empuja en la pila de navegación.
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }
    #else
    private let isCompact = false
    #endif

    private var topPad: CGFloat {
        #if os(macOS)
        return 52
        #else
        return isCompact ? 8 : 20
        #endif
    }

    /// Los listados verticales usan dos columnas fluidas en iPhone; en iPad y
    /// Mac conservan las tarjetas grandes, sin solaparse.
    private var verticalEventCardWidth: CGFloat? { isCompact ? nil : 340 }
    private var verticalEventColumns: [GridItem] {
        if isCompact {
            return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        }
        return [GridItem(.adaptive(minimum: 340, maximum: 380), spacing: 24)]
    }

    var body: some View {
        ZStack {
            layout
                .opacity(vm.hasLoaded ? 1 : 0)
            if !vm.hasLoaded {
                Color.black.ignoresSafeArea()
                ProgressView().controlSize(.large)
            }
        }
            .task { await vm.load() }
            .task { bigClubTeams = await ESPNService.bigClubTeams() }
            .task { countryTeams = await ESPNService.countryTeams() }
            .onChange(of: section) { _, _ in
                matchFilter = nil
                competitionPath = NavigationPath()
            }
            #if os(iOS)
            .fullScreenCover(item: $playing) { channel in
                PlayerView(channel: channel, resume: playResume, onClose: { playing = nil })
                    .preferredColorScheme(.dark)
            }
            #endif
    }

    @ViewBuilder
    private var layout: some View {
        #if os(iOS)
        if isCompact { compactLayout } else { splitLayout }
        #else
        macLayout
        #endif
    }

    // Barra lateral "clásica" (NavigationSplitView + List): sigue usándose
    // en iPad. En Mac la reemplaza `macLayout`.
    private var splitLayout: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack(path: $competitionPath) {
                page
                    .navigationDestination(for: Competition.self, destination: competitionDestination)
                    .navigationDestination(for: TeamNavTarget.self, destination: teamDestination)
                    .navigationDestination(for: EventItem.self, destination: eventDestination)
            }
        }
    }

    #if os(macOS)
    /// Barra lateral nativa de macOS 26 (Tahoe): un `TabView` con el estilo
    /// `sidebarAdaptable` —el mismo patrón que usan Música, Podcasts o
    /// Fotos— en vez de `NavigationSplitView`, para heredar el look
    /// "Liquid Glass" y el comportamiento nativo (barra flotante,
    /// redimensionable, etc.) que da el sistema.
    private var macLayout: some View {
        TabView(selection: macSelection) {
            Tab(AppSection.search.title, systemImage: AppSection.search.icon, value: AppSection.search) {
                macDetailContent
            }
            Tab(AppSection.home.title, systemImage: AppSection.home.icon, value: AppSection.home) {
                macDetailContent
            }
            Tab(AppSection.live.title, systemImage: AppSection.live.icon, value: AppSection.live) {
                macDetailContent
            }
            TabSection("Biblioteca") {
                Tab(AppSection.replays.title, systemImage: AppSection.replays.icon, value: AppSection.replays) {
                    macDetailContent
                }
                Tab(AppSection.channels.title, systemImage: AppSection.channels.icon, value: AppSection.channels) {
                    macDetailContent
                }
                Tab(AppSection.settings.title, systemImage: AppSection.settings.icon, value: AppSection.settings) {
                    macDetailContent
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // Igual que antes con NavigationSplitView: transparente para que el
        // hero llegue arriba de la ventana sin barra de título.
        .toolbarBackground(.hidden, for: .windowToolbar)
    }

    /// `section` es opcional para poder compartirlo con la navegación de
    /// iOS; el `TabView` nativo necesita un valor no opcional para `selection`.
    private var macSelection: Binding<AppSection> {
        Binding(get: { section ?? .home }, set: { section = $0 })
    }

    private var macDetailContent: some View {
        NavigationStack(path: $competitionPath) {
            page
                .navigationDestination(for: Competition.self, destination: competitionDestination)
                .navigationDestination(for: TeamNavTarget.self, destination: teamDestination)
                .navigationDestination(for: EventItem.self, destination: eventDestination)
        }
        .ignoresSafeArea(edges: .top)
    }
    #endif

    #if os(iOS)
    /// iPhone: sin barra lateral ni botón atrás. La pastilla de arriba se
    /// queda igual que antes; en iOS lleva un 5º item ("Extra") que abre las
    /// secciones (antes en la barra lateral) como menú nativo.
    private var compactLayout: some View {
        NavigationStack(path: $leaguePath) {
            page
                .toolbar {
                    if (section ?? .home) != .home {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                withAnimation(.smooth) { section = .home }
                            } label: {
                                Label("Inicio", systemImage: "chevron.backward")
                            }
                        }
                    }
                }
                .toolbarBackground(.hidden, for: .navigationBar)
                .navigationDestination(for: LeagueDestination.self, destination: leagueDestination)
                .navigationDestination(for: TeamNavTarget.self, destination: teamDestination)
                .navigationDestination(for: EventItem.self, destination: eventDestination)
        }
    }

    /// Contenido de cada pantalla de liga empujada. Sin barra de arriba propia
    /// ni botón "Atrás" a mano: los provee la navegación nativa (con su
    /// cristal líquido) al ser un `navigationDestination` real.
    @ViewBuilder
    private func leagueDestination(_ destination: LeagueDestination) -> some View {
        switch destination {
        case .competition(let competition):
            competitionDestination(competition)
                .navigationBarTitleDisplayMode(.inline)
        case .extra:
            extraPage
        }
    }

    /// Pantalla completa (no un menú flotante) con las secciones que en
    /// iPad/Mac viven en la barra lateral — con el logo de cada liga, igual
    /// que ahí.
    private var extraPage: some View {
        List {
            Section {
                extraRow(.search)
                extraRow(.home)
                extraRow(.live)
            }
            Section("Biblioteca") {
                extraRow(.replays)
                extraRow(.channels)
                extraRow(.settings)
            }
        }
        .navigationTitle("Más")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Selecciona la sección y vuelve a la raíz — como cerraba antes el menú.
    private func extraRow(_ item: AppSection) -> some View {
        Button {
            section = item
            leaguePath = NavigationPath()
        } label: {
            Label(item.title, systemImage: item.icon)
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }
    #endif

    /// Pantalla de una competición: Partidos/Tabla/Calendario en pestañas,
    /// empujada como ruta real (con botón "Atrás" nativo) desde el mosaico
    /// "Competiciones" de Inicio.
    @ViewBuilder
    private func competitionDestination(_ competition: Competition) -> some View {
        StandingsView(competition: competition,
                      items: vm.items(for: .competition(competition)),
                      onSelectMatch: open)
            .navigationTitle(competition.name)
    }

    /// Ficha de un equipo tocado desde el riel "Equipos" de Inicio: a
    /// diferencia de tocarlo dentro de una competición, aquí el calendario
    /// junta todas las competiciones del equipo (ver `TeamNavTarget`).
    private func teamDestination(_ target: TeamNavTarget) -> some View {
        TeamDetailView(team: target.team, competition: target.competition,
                       combineCompetitions: target.combineCompetitions, onSelectMatch: open)
    }

    /// Ficha de un partido empujada en la pila, con el botón "Atrás" nativo.
    /// Sin título: la barra solo lleva la flecha sobre la portada.
    private func eventDestination(_ item: EventItem) -> some View {
        EventDetailView(item: item,
                        resolve: { vm.channel(for: $0) },
                        onPlay: play,
                        onPlayHighlight: playHighlight,
                        previewsPaused: previewsPaused,
                        nowPlaying: nowPlaying?.streamURL)
            .onAppear { openEventCount += 1 }
            .onDisappear { openEventCount -= 1 }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
    }

    /// Con un canal abierto, las vistas previas no deben quitarle ancho de banda.
    private var previewsPaused: Bool {
        #if os(macOS)
        let isPlaying = playerCoordinator.channel != nil
        #else
        let isPlaying = playing != nil
        #endif
        return isPlaying || !previewsEnabled
    }

    /// Canal en el reproductor ahora mismo.
    private var nowPlaying: Channel? {
        #if os(macOS)
        playerCoordinator.channel
        #else
        playing
        #endif
    }

    private func play(_ channel: Channel, resume: Bool) {
        #if os(macOS)
        playerCoordinator.resume = resume
        playerCoordinator.channel = channel
        openWindow(id: "player")
        #else
        playResume = resume
        playing = channel
        #endif
    }

    /// Nunca dentro de la app: el resumen ya se confirmó publicado en el
    /// canal de la fuente (búsqueda en `YouTubeHighlightsService`), así que
    /// solo hace falta enlazar directo a la app de YouTube con ese video.
    private func playHighlight(_ highlight: YouTubeHighlightsService.Highlight) {
        openURL(highlight.watchURL)
    }

    private func open(_ item: EventItem) {
        #if os(iOS)
        if isCompact {
            leaguePath.append(item)
            return
        }
        #endif
        competitionPath.append(item)
    }

    /// El hero de respaldo usa partidos recientes y su acción principal abre
    /// el resumen oficial de ESPN Deportes directamente, sin pasar por la
    /// ficha del partido.
    private func playESPNHighlight(for item: EventItem) {
        Task {
            guard let highlight = await YouTubeHighlightsService.highlight(for: .espn,
                                                                            home: item.event.home,
                                                                            away: item.event.away) else { return }
            openURL(highlight.watchURL)
        }
    }

    /// Siempre empuja una pantalla nueva (Partidos/Tabla/Calendario) con
    /// botón "Atrás" nativo, en vez de sustituir el contenido de Inicio.
    private func selectCompetition(_ competition: Competition) {
        #if os(iOS)
        if isCompact {
            leaguePath.append(LeagueDestination.competition(competition))
            return
        }
        #endif
        competitionPath.append(competition)
    }

    // MARK: - Barra lateral

    private var sidebar: some View {
        List(selection: $section) {
            sidebarRow(.search)
            sidebarRow(.home)
            sidebarRow(.live)
            Section("Biblioteca") {
                sidebarRow(.replays)
                sidebarRow(.channels)
                sidebarRow(.settings)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        .toolbar(removing: .sidebarToggle)
    }

    private func sidebarRow(_ item: AppSection) -> some View {
        Label(item.title, systemImage: item.icon)
            .font(.body.weight(.medium))
            .tag(item)
    }

    /// La barra de arriba: "Para ti" es la home; una marca abre la cuadrícula
    /// filtrada por ese canal.
    private var navSelection: Binding<String> {
        Binding(
            get: {
                switch matchFilter {
                case .none: return "Para ti"
                case .channel(let name): return name
                case .competition: return ""
                }
            },
            set: { newValue in
                withAnimation(.smooth) {
                    matchFilter = newValue == "Para ti" ? nil : .channel(newValue)
                }
            }
        )
    }

    /// En iOS, el 5º item de la pastilla ("Extra") empuja `extraPage`. En Mac
    /// es `nil` y la pastilla se queda con sus 4 items de siempre.
    private var onExtraTap: (() -> Void)? {
        #if os(iOS)
        { leaguePath.append(LeagueDestination.extra) }
        #else
        nil
        #endif
    }

    // MARK: - Páginas

    @ViewBuilder
    private var page: some View {
        switch section ?? .home {
        case .search:
            searchPage
        case .home:
            Group {
                if let filter = matchFilter {
                    MatchesGridView(filter: filter,
                                    items: vm.items(for: filter),
                                    onSelect: open)
                        .transition(.opacity)
                } else {
                    homePage
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.3), value: matchFilter)
            .overlay(alignment: .top) {
                TopNavPill(selection: navSelection, onExtraTap: onExtraTap)
                    .padding(.top, 14)
            }
        case .live:
            gridPage(title: "En vivo", items: vm.liveItems,
                     emptyTitle: "No hay partidos en vivo",
                     emptyText: "Cuando empiece un partido de la cartelera aparecerá aquí.",
                     emptyIcon: "dot.radiowaves.left.and.right")
        case .replays:
            gridPage(title: "Repeticiones", items: vm.finishedItems,
                     emptyTitle: "Aún no hay repeticiones",
                     emptyText: "Los partidos terminados aparecerán aquí.",
                     emptyIcon: "clock.arrow.circlepath")
        case .channels:
            channelsPage
        case .settings:
            SettingsView()
                .safeAreaPadding(.top, topPad)
        }
    }

    /// Deportes que el usuario dejó activos en Ajustes → "Deportes en Inicio".
    private var enabledSports: Set<String> { SportsFilterSettings.enabledSet(from: enabledSportsRaw) }

    private func passesSportsFilter(_ item: EventItem) -> Bool {
        enabledSports.contains(item.card.category ?? item.event.sport ?? "Otros")
    }

    private func passesSportsFilter(_ card: Channel) -> Bool {
        enabledSports.contains(card.category ?? "Otros")
    }

    private var homePage: some View {
        let scheduledHero = vm.heroItems.filter(passesSportsFilter)
        let visibleLive = vm.liveItems.filter(passesSportsFilter)
        let visibleGroups = vm.leagueGroups
            .map { ChannelsViewModel.LeagueGroup(name: $0.name, items: $0.items.filter(passesSportsFilter)) }
            .filter { !$0.items.isEmpty }
        let visibleRecent = vm.recentMatches.filter(passesSportsFilter)
        let usesRecentFallback = scheduledHero.isEmpty && !visibleRecent.isEmpty
        let heroItems = usesRecentFallback ? Array(visibleRecent.prefix(5)) : scheduledHero

        return GeometryReader { geo in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 32) {
                    if !heroItems.isEmpty {
                        HeroCarousel(items: heroItems,
                                     height: heroHeight(geo.size.height),
                                     paused: openEventCount > 0 || previewsPaused,
                                     onOpen: open,
                                     onPlay: { item in
                                         if item.isHighlightsOnly {
                                             playESPNHighlight(for: item)
                                         } else {
                                             play(item.card, resume: false)
                                         }
                                     })
                    } else if vm.isLoading {
                        ProgressView().controlSize(.large)
                            .frame(maxWidth: .infinity)
                            .frame(height: heroHeight(geo.size.height))
                    }

                    if !visibleLive.isEmpty {
                        EventRail(title: "En vivo ahora", items: visibleLive, hPad: hPad, onSelect: open)
                    }

                    if enabledSports.contains("Fútbol") {
                        competitionsRow
                        bigClubsRow
                    }

                    ForEach(visibleGroups) { group in
                        EventRail(title: group.name, items: group.items, hPad: hPad, onSelect: open)
                    }

                    // No depende de la cartelera del día: sobrevive al cambio de fecha.
                    if !visibleRecent.isEmpty {
                        EventRail(title: "Partidos recientes", items: visibleRecent, hPad: hPad, onSelect: open)
                    }

                    if let error = vm.loadError {
                        Label("Mostrando demo — \(error)", systemImage: "wifi.exclamationmark")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, hPad)
                    }
                }
                .padding(.bottom, 32)
            }
            .refreshable { await vm.load() }
        }
        #if os(iOS)
        .ignoresSafeArea(edges: .top)
        #endif
    }

    private func gridPage(title: String, items: [EventItem], emptyTitle: String,
                          emptyText: String, emptyIcon: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(title).font(.largeTitle.weight(.bold))
                if items.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: emptyIcon,
                                           description: Text(emptyText))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                } else {
                    LazyVGrid(columns: verticalEventColumns, alignment: .leading,
                              spacing: isCompact ? 16 : 24) {
                        ForEach(items) { item in
                            EventCard(channel: item.card, action: { open(item) }, width: verticalEventCardWidth)
                        }
                    }
                }
            }
            .padding(.horizontal, hPad)
            .padding(.top, topPad)
            .padding(.bottom, 32)
        }
    }

    private var searchPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Buscar").font(.largeTitle.weight(.bold))

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField("Partidos, equipos o competiciones", text: $vm.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                if !vm.query.isEmpty {
                    Button { vm.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.primary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if vm.query.isEmpty {
                ContentUnavailableView("Busca un partido", systemImage: "sportscourt",
                                       description: Text("Escribe el nombre de un equipo o una competición."))
                    .frame(maxHeight: .infinity)
            } else {
                EventSearchResults(items: vm.searchResults, onSelect: open)
            }
        }
        .padding(.horizontal, hPad)
        .padding(.top, topPad)
        .onAppear { searchFocused = true }
    }

    /// Canales en directo: pausado en la home, disponible desde la biblioteca.
    private var channelsPage: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                Text("Canales")
                    .font(.largeTitle.weight(.bold))
                    .padding(.horizontal, hPad)

                if vm.channels.isEmpty {
                    ContentUnavailableView("Sin canales", systemImage: "tv")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    categoriesRow
                    if let category = selectedCategory {
                        Rail(title: category, items: vm.rail(for: category), hPad: hPad, onSelect: { play($0, resume: false) })
                    } else {
                        ForEach(vm.categories, id: \.self) { category in
                            Rail(title: category, items: vm.rail(for: category), hPad: hPad, onSelect: { play($0, resume: false) })
                        }
                    }
                }
            }
            .padding(.top, topPad)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Filas

    private var competitionsRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Competiciones").padding(.horizontal, hPad)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 18) {
                    ForEach(Competition.featured) { competition in
                        CompetitionTile(competition: competition, isSelected: false) {
                            selectCompetition(competition)
                        }
                    }
                }
                .padding(.horizontal, hPad)
                // Aire suficiente para el brillo de color y el zoom del hover:
                // el ScrollView recorta todo lo que sale de su marco.
                .padding(.vertical, 30)
            }
        }
    }

    /// Grandes equipos europeos, siempre visibles en Inicio (a diferencia del
    /// riel "Equipos" de dentro de una competición): al tocar uno se junta el
    /// calendario de su competición doméstica y europea.
    private var bigClubsRow: some View {
        let mode = TeamsMode(rawValue: teamsModeRaw) ?? .clubs
        let teams = mode == .clubs ? bigClubTeams : countryTeams
        return Group {
            if !bigClubTeams.isEmpty || !countryTeams.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 16) {
                        SectionHeader(title: "Equipos")
                        Picker("Equipos", selection: $teamsModeRaw) {
                            ForEach(TeamsMode.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 190)
                    }
                    .padding(.horizontal, hPad)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 18) {
                            ForEach(teams) { featured in
                                NavigationLink(value: TeamNavTarget(team: featured.team,
                                                                    competition: featured.competition,
                                                                    combineCompetitions: true)) {
                                    TeamTile(team: featured.team)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, hPad)
                        .padding(.vertical, 20)
                    }
                }
            }
        }
    }

    private var categoriesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                CategoryCircle(title: "Todos", isSelected: selectedCategory == nil) {
                    withAnimation(.snappy) { selectedCategory = nil }
                }
                ForEach(vm.categories, id: \.self) { category in
                    CategoryCircle(title: category, isSelected: selectedCategory == category) {
                        withAnimation(.snappy) { selectedCategory = category }
                    }
                }
            }
            .padding(.horizontal, hPad)
        }
    }
}

// MARK: - Riel de partidos

struct EventRail: View {
    let title: String
    let items: [EventItem]
    let hPad: CGFloat
    let onSelect: (EventItem) -> Void

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var cardWidth: CGFloat { sizeClass == .compact ? 290 : 340 }
    #else
    private let cardWidth: CGFloat = 340
    #endif

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: title).padding(.horizontal, hPad)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(items) { item in
                            EventCard(channel: item.card, action: { onSelect(item) }, width: cardWidth)
                        }
                    }
                    .padding(.horizontal, hPad)
                    .padding(.vertical, 6)
                }
            }
        }
    }
}

// MARK: - Resultados de búsqueda (partidos)

struct EventSearchResults: View {
    let items: [EventItem]
    let onSelect: (EventItem) -> Void

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    #endif

    private var cardWidth: CGFloat? { compact ? nil : 340 }
    private var columns: [GridItem] {
        if compact {
            return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        }
        return [GridItem(.adaptive(minimum: 340, maximum: 380), spacing: 24)]
    }

    var body: some View {
        ScrollView {
            if items.isEmpty {
                ContentUnavailableView("Sin resultados", systemImage: "magnifyingglass")
                    .padding(.top, 120)
            } else {
                LazyVGrid(columns: columns, spacing: compact ? 16 : 18) {
                    ForEach(items) { item in
                        EventCard(channel: item.card, action: { onSelect(item) }, width: cardWidth)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
        }
    }
}

// MARK: - Riel horizontal

struct Rail: View {
    let title: String
    let items: [Channel]
    let hPad: CGFloat
    let onSelect: (Channel) -> Void

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: title).padding(.horizontal, hPad)
                ScrollView(.horizontal, showsIndicators: false) {
                    // Lazy: solo se construyen (y descargan imágenes de) las
                    // tarjetas visibles, no las 20 del riel entero.
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(items.prefix(14)) { item in
                            EventCard(channel: item) { onSelect(item) }
                        }
                    }
                    .padding(.horizontal, hPad)
                }
            }
        }
    }
}

// MARK: - Resultados de búsqueda

struct SearchResults: View {
    let items: [Channel]
    let onSelect: (Channel) -> Void
    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 16)]

    var body: some View {
        ScrollView {
            if items.isEmpty {
                ContentUnavailableView("Sin resultados", systemImage: "magnifyingglass")
                    .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(items) { item in
                        EventCard(channel: item, action: { onSelect(item) }, width: 260)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(18)
            }
        }
    }
}

// MARK: - Carrusel destacado (hero)

/// Portada alta estilo Apple TV: arte a la derecha, la información a la
/// izquierda y la señal en vivo del slide enfocado de fondo.
struct HeroCarousel: View {
    let items: [EventItem]
    var height: CGFloat = 520
    /// Con la ficha de un partido o un canal abiertos (o las vistas previas
    /// apagadas en Ajustes), el hero deja de reproducir.
    var paused = false
    let onOpen: (EventItem) -> Void
    /// Reproduce el canal disponible o abre el resumen cuando es un reciente.
    let onPlay: (EventItem) -> Void

    @State private var currentID: String?
    /// Vista previa en vivo del slide enfocado (silenciada).
    @State private var preview: AVPlayer?
    @State private var previewID: String?
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(items) { item in
                    HeroSlide(item: item,
                              preview: previewID == item.id ? preview : nil,
                              onOpen: onOpen,
                              onPlay: onPlay)
                        .containerRelativeFrame(.horizontal)
                        .frame(height: height)
                        .id(item.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentID)
        .frame(height: height)
        .overlay(alignment: .bottom) {
            if items.count > 1 { pageDots.padding(.bottom, 22) }
        }
        .onAppear {
            currentID = items.first?.id
            startPreview(for: items.first?.id)
        }
        .onChange(of: items) { _, newItems in
            if !newItems.contains(where: { $0.id == currentID }) {
                currentID = newItems.first?.id
            }
            startPreview(for: currentID)
        }
        .onChange(of: currentID) { _, id in startPreview(for: id) }
        .onChange(of: paused) { _, isPaused in
            if isPaused { stopPreview() } else { startPreview(for: currentID) }
        }
        .onDisappear { stopPreview() }
    }

    private var pageDots: some View {
        HStack(spacing: 9) {
            ForEach(items) { item in
                Button {
                    withAnimation(.smooth) { currentID = item.id }
                } label: {
                    Circle()
                        .fill(.white.opacity(currentID == item.id ? 1 : 0.35))
                        .frame(width: 7, height: 7)
                        .padding(3)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.snappy, value: currentID)
    }

    /// Arranca la señal del slide enfocado tras una pausa corta, para no abrir
    /// un stream por cada slide mientras el usuario pasa el carrusel.
    private func startPreview(for id: String?) {
        stopPreview()
        guard !paused, let id,
              let item = items.first(where: { $0.id == id })?.card,
              item.canPreview, let url = item.streamURL else { return }

        previewTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            let player = AVPlayer(url: url)
            player.isMuted = true
            await MainActor.run {
                guard !Task.isCancelled else { return }
                preview = player
                previewID = id
                player.play()
            }
        }
    }

    private func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        preview?.pause()
        preview = nil
        previewID = nil
    }
}

struct HeroSlide: View {
    let item: EventItem
    var preview: AVPlayer?
    let onOpen: (EventItem) -> Void
    let onPlay: (EventItem) -> Void

    private var channel: Channel { item.card }
    private var primaryActionTitle: String { item.isHighlightsOnly ? "Ver resumen" : "Ver partido" }

    @State private var added = false

    #if os(macOS)
    private let eyebrowSize: CGFloat = 13
    private let leagueLogoSize: CGFloat = 26
    private let teamSize: CGFloat = 38
    private let crestSize: CGFloat = 34
    private let metaSize: CGFloat = 15
    private let buttonSize: CGFloat = 15
    private let pad: CGFloat = 56
    #else
    private let eyebrowSize: CGFloat = 11
    private let leagueLogoSize: CGFloat = 20
    private let teamSize: CGFloat = 26
    private let crestSize: CGFloat = 24
    private let metaSize: CGFloat = 13
    private let buttonSize: CGFloat = 14
    private let pad: CGFloat = 20
    #endif

    private var hasPlayers: Bool {
        channel.homePlayerURL != nil || channel.awayPlayerURL != nil
    }
    private var hasCrests: Bool {
        channel.homeLogoURL != nil || channel.awayLogoURL != nil
    }
    private var showsScore: Bool {
        (channel.isLive || channel.isFinal) && channel.homeScore != nil
    }
    /// "Local vs Visitante" → nombres por separado para las filas de equipo.
    private var teams: (home: String, away: String)? {
        let parts = channel.name.components(separatedBy: " vs ")
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }
    private var headline: String {
        channel.subtitle ?? channel.category ?? "Kerter+"
    }
    private var meta: String {
        [channel.dateLabel, channel.startText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    // El tamaño lo fija `Color.clear` (el frame del carrusel). Fondo, video y
    // texto van como overlays: una imagen `.fill` más grande no puede inflar
    // el layout y empujar el contenido fuera del recorte.
    var body: some View {
        Color.clear
            .overlay {
                ZStack {
                    Group {
                        if let cover = channel.heroImageURL {
                            // 1) Portada oficial del partido (TheSportsDB).
                            Color.black.overlay {
                                CachedImage(url: cover, contentMode: .fill,
                                            placeholder: .clear)
                            }
                            .clipped()
                        } else if hasPlayers || hasCrests {
                            // 2) Portada compuesta: estadio + jugadores.
                            PlayerBackdrop(channel: channel)
                        } else {
                            // 3) Colores de los equipos / póster genérico.
                            EventPoster(channel: channel)
                        }
                    }
                    .backgroundExtensionEffect()

                    // La señal en vivo del canal, encima del fondo.
                    if let preview {
                        VideoPreview(player: preview)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.5), value: preview != nil)
                .heroParallax()
            }
            .overlay {
                ZStack {
                    #if os(macOS)
                    // Oscurece la mitad izquierda, donde va el texto.
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.92), location: 0),
                        .init(color: .black.opacity(0.7), location: 0.35),
                        .init(color: .clear, location: 0.7),
                    ], startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.clear, .black.opacity(0.75)],
                                   startPoint: .init(x: 0.5, y: 0.45), endPoint: .bottom)
                    #else
                    // iOS: el texto va centrado abajo, así que solo oscurece abajo.
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0.3),
                        .init(color: .black.opacity(0.6), location: 0.6),
                        .init(color: .black.opacity(0.92), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                    #endif
                }
            }
            #if os(macOS)
            .overlay(alignment: .bottomLeading) {
                content
                    .padding(.leading, pad)
                    .padding(.trailing, pad)
                    .padding(.bottom, 64)
            }
            #else
            .overlay(alignment: .bottom) {
                centeredContent
                    .padding(.horizontal, pad)
                    .padding(.bottom, 52)
            }
            #endif
            .clipped()
            .environment(\.colorScheme, .dark)
    }

    #if os(iOS)
    /// iOS: escudos grandes en el centro con un "VS" artístico de por medio,
    /// nombres debajo, competición y solo "Ver partido" + info, todo centrado.
    private var centeredContent: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                crestColumn(logo: channel.homeLogoURL, name: teams?.home ?? channel.name)
                versus
                    .frame(height: 84)
                crestColumn(logo: channel.awayLogoURL, name: teams?.away ?? "")
            }

            HStack(spacing: 8) {
                if let logo = Competition.matching(league: channel.subtitle)?.logoURL {
                    CachedImage(url: logo, contentMode: .fit, placeholder: .clear)
                        .frame(width: leagueLogoSize, height: leagueLogoSize)
                }
                Text(headline.uppercased())
                    .font(.system(size: eyebrowSize, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                statusPill
            }
            .padding(.top, 16)

            if !meta.isEmpty {
                Text(meta)
                    .font(.system(size: metaSize))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 6)
            }

            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        if item.isHighlightsOnly || channel.streamURL != nil {
                            onPlay(item)
                        } else {
                            onOpen(item)
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "play.fill")
                            Text(primaryActionTitle)
                        }
                        .font(.system(size: buttonSize, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .controlSize(.large)

                    Button { onOpen(item) } label: {
                        Image(systemName: "info")
                            .font(.system(size: buttonSize, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                }
            }
            .padding(.top, 20)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .shadow(color: .black.opacity(0.35), radius: 12, y: 2)
    }

    private func crestColumn(logo: URL?, name: String) -> some View {
        VStack(spacing: 10) {
            CachedImage(url: logo, contentMode: .fit, placeholder: .clear)
                .frame(width: 84, height: 84)
            Text(name.uppercased())
                .font(.system(size: 17, weight: .bold).width(.condensed))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    /// "VS" en cursiva serif black; con el partido empezado, el marcador.
    @ViewBuilder
    private var versus: some View {
        if showsScore, let h = channel.homeScore, let a = channel.awayScore {
            Text("\(h) - \(a)")
                .font(.system(size: 30, weight: .black, design: .serif))
                .monospacedDigit()
                .foregroundStyle(.white)
        } else {
            Text("VS")
                .font(.system(size: 34, weight: .black, design: .serif).italic())
                .tracking(2)
                .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.55)],
                                                startPoint: .top, endPoint: .bottom))
        }
    }
    #endif

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Antetítulo: logo + competición en versalitas pequeñas, y el estado.
            HStack(spacing: 10) {
                if let logo = Competition.matching(league: channel.subtitle)?.logoURL {
                    CachedImage(url: logo, contentMode: .fit, placeholder: .clear)
                        .frame(width: leagueLogoSize, height: leagueLogoSize)
                }
                Text(headline.uppercased())
                    .font(.system(size: eyebrowSize, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                statusPill
            }
            .padding(.bottom, 16)

            // Protagonistas: los equipos, grandes y condensados.
            if let teams {
                VStack(alignment: .leading, spacing: 4) {
                    teamRow(logo: channel.homeLogoURL, name: teams.home, score: channel.homeScore)
                    teamRow(logo: channel.awayLogoURL, name: teams.away, score: channel.awayScore)
                }
            } else {
                Text(channel.name)
                    .font(.system(size: teamSize, weight: .bold).width(.condensed))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }

            // Detalle discreto.
            if !meta.isEmpty {
                Text(meta)
                    .font(.system(size: metaSize))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 12)
            }

            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        if item.isHighlightsOnly || channel.streamURL != nil {
                            onPlay(item)
                        } else {
                            onOpen(item)
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "play.fill")
                            Text(primaryActionTitle)
                        }
                            .font(.system(size: buttonSize, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .controlSize(.large)

                    Button { onOpen(item) } label: {
                        Image(systemName: "info")
                            .font(.system(size: buttonSize, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)

                    Button {
                        withAnimation(.snappy) { added.toggle() }
                    } label: {
                        Image(systemName: added ? "checkmark" : "plus")
                            .font(.system(size: buttonSize, weight: .semibold))
                            .foregroundStyle(.white)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                }
            }
            .padding(.top, 22)
        }
        .shadow(color: .black.opacity(0.35), radius: 12, y: 2)
        .frame(maxWidth: 480, alignment: .leading)
    }

    @ViewBuilder
    private var statusPill: some View {
        if channel.isLive {
            LiveBadge()
        } else if let text = channel.statusPill ?? channel.startText, !text.isEmpty {
            Text(text)
                .font(.system(size: eyebrowSize, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: Capsule())
        }
    }

    private func teamRow(logo: URL?, name: String, score: String?) -> some View {
        HStack(spacing: 14) {
            CachedImage(url: logo, contentMode: .fit, placeholder: .clear)
                .frame(width: crestSize, height: crestSize)
            Text(name.uppercased())
                .font(.system(size: teamSize, weight: .bold).width(.condensed))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if showsScore, let score {
                Text(score)
                    .font(.system(size: teamSize, weight: .bold).width(.condensed))
                    .foregroundStyle(.white.opacity(0.85))
                    .monospacedDigit()
            }
        }
    }
}

/// Fondo del hero tipo streaming premium: imagen de estadio (Champions o
/// general) + recortes HD de un jugador de cada equipo (ESPN), anclados abajo.
struct PlayerBackdrop: View {
    let channel: Channel

    #if os(macOS)
    private let playerW: CGFloat = 240
    private let playerH: CGFloat = 340
    #else
    private let playerW: CGFloat = 190
    private let playerH: CGFloat = 280
    #endif

    private var backgroundName: String {
        (channel.subtitle ?? "").localizedCaseInsensitiveContains("champions")
            ? "HeroBGChampions" : "HeroBGDefault"
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Overlay sobre Color.clear para que la imagen `.fill` no agrande
            // el ZStack (si no, los jugadores anclados abajo quedan fuera).
            Color.clear
                .overlay {
                    Image(backgroundName)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                .clipped()

            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.15), .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)

            HStack(alignment: .bottom, spacing: -18) {
                if channel.homePlayerURL != nil { player(channel.homePlayerURL) }
                if channel.awayPlayerURL != nil { player(channel.awayPlayerURL) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 8)
        }
    }

    private func player(_ url: URL?) -> some View {
        CachedImage(url: url, contentMode: .fit, placeholder: .clear)
            .frame(width: playerW, height: playerH, alignment: .bottom)
            // Desvanece la base para que no se vea el corte del recorte.
            .mask(
                LinearGradient(stops: [
                    .init(color: .black, location: 0.0),
                    .init(color: .black, location: 0.80),
                    .init(color: .clear, location: 1.0)
                ], startPoint: .top, endPoint: .bottom)
            )
            .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
    }
}
