import Foundation
import Combine

/// Un partido de la cartelera con su tarjeta visual ya resuelta (escudos,
/// colores y marcador de ESPN). Los canales solo se muestran al entrar.
struct EventItem: Identifiable, Hashable {
    let event: LiveEvent
    var card: Channel
    /// Partido que no viene de la cartelera de Kerter (calendario de una
    /// competición o "Partidos recientes"): no tiene canales propios, así que
    /// la ficha muestra resúmenes de YouTube en vez del selector de canal.
    var isHighlightsOnly: Bool = false
    var id: String { event.id }

    /// Partido terminado sacado directamente de ESPN (sin asignación de
    /// Kerter) — para el calendario y "Partidos recientes".
    static func highlightsOnly(_ info: ESPNService.MatchInfo, league: String) -> EventItem {
        let event = LiveEvent(id: "highlights-\(info.id)", home: info.home, away: info.away,
                              league: league, sport: "Fútbol", time: nil,
                              homeLogo: info.homeLogo, awayLogo: info.awayLogo, channels: [])
        return EventItem(event: event, card: ESPNService.channel(from: info, league: league),
                         isHighlightsOnly: true)
    }
}

/// Filtro de la pantalla de cuadrícula de partidos.
enum MatchFilter: Hashable {
    /// Marca de la barra superior: "Kerter+", "DAZN", "ESPN".
    case channel(String)
    case competition(Competition)
}

@MainActor
final class ChannelsViewModel: ObservableObject {
    /// Canales del backend: ya no se listan, solo sirven para reproducir la
    /// opción que el usuario elija dentro de un partido.
    @Published private(set) var channels: [Channel] = []
    @Published private(set) var isLoading = false
    /// Falso hasta que termina la primera carga completa (cartelera, ESPN,
    /// Champions): mientras tanto la app solo muestra el loader.
    @Published private(set) var hasLoaded = false
    @Published private(set) var loadError: String?
    @Published var query: String = ""
    /// Cartelera real de Kerter: partidos con el grupo de canales que los transmiten.
    @Published private(set) var events: [LiveEvent] = []
    @Published private(set) var eventItems: [EventItem] = []
    /// Equipos que juegan la Champions esta temporada, para priorizar el hero.
    @Published private(set) var championsTeams: Set<String> = []
    /// Últimos partidos terminados de LaLiga y Champions (las únicas ligas con
    /// resumen), para "Partidos recientes" en la home — no dependen de la
    /// cartelera del día de Kerter, así que sobreviven al cambio de fecha.
    @Published private(set) var recentMatches: [EventItem] = []

    private let api = APIClient.shared
    private unowned let auth: AuthManager

    init(auth: AuthManager) { self.auth = auth }

    // MARK: - Secciones de la home

    /// Hero: en vivo primero y, dentro de eso, el Barça siempre delante, luego
    /// el Madrid, luego cualquier partido con un equipo de Champions esta
    /// temporada (para que un Getafe-Osasuna nunca adelante a un Barça-Atlético)
    /// y el resto tal como ya viene de la cartelera.
    var heroItems: [EventItem] {
        eventItems.enumerated()
            .sorted { a, b in
                let la = a.element.card.isLive ? 0 : 1, lb = b.element.card.isLive ? 0 : 1
                if la != lb { return la < lb }
                let ta = heroTier(for: a.element.event), tb = heroTier(for: b.element.event)
                if ta != tb { return ta < tb }
                return a.offset < b.offset
            }
            .prefix(5)
            .map(\.element)
    }

    var hero: [Channel] { heroItems.map(\.card) }

    private func heroTier(for event: LiveEvent) -> Int {
        if isTeam(event.home, "Barcelona") || isTeam(event.away, "Barcelona") { return 0 }
        if isTeam(event.home, "Real Madrid") || isTeam(event.away, "Real Madrid") { return 1 }
        if inChampions(event.home) || inChampions(event.away) { return 2 }
        return 3
    }

    private func isTeam(_ name: String, _ target: String) -> Bool {
        ESPNService.similar(name, target)
    }

    private func inChampions(_ name: String) -> Bool {
        championsTeams.contains { ESPNService.similar($0, name) }
    }

    /// Se carga una sola vez por sesión: la lista de equipos de la Champions
    /// no cambia durante el día.
    private func loadChampionsTeams() async {
        guard championsTeams.isEmpty else { return }
        let standings = await StandingsService.standings(league: "uefa.champions")
        championsTeams = Set((standings?.groups.flatMap(\.rows).map(\.team)) ?? [])
    }

    var liveItems: [EventItem] { eventItems.filter { $0.card.isLive } }

    /// Repeticiones: de momento, los partidos de la cartelera que ya terminaron.
    var finishedItems: [EventItem] { eventItems.filter { $0.card.isFinal } }

    // MARK: - Canales (pantalla "Canales" de la biblioteca)

    private static let categoryOrder = SportsFilterSettings.allSports

    var categories: [String] {
        let present = Set(channels.compactMap { $0.category })
        let ordered = Self.categoryOrder.filter { present.contains($0) }
        return ordered + present.subtracting(ordered).sorted()
    }

    func rail(for category: String) -> [Channel] {
        channels.filter { $0.category == category }
            .sorted { ($0.isLive ? 0 : 1, $0.name) < ($1.isLive ? 0 : 1, $1.name) }
    }

    struct LeagueGroup: Identifiable {
        let name: String
        let items: [EventItem]
        var id: String { name }
    }

    /// Un riel por competición, en el orden en que aparecen en la cartelera.
    var leagueGroups: [LeagueGroup] {
        var order: [String] = []
        var map: [String: [EventItem]] = [:]
        for item in eventItems {
            let league = item.event.league ?? ""
            let name = league.isEmpty ? "Otros partidos" : league
            if map[name] == nil { order.append(name) }
            map[name, default: []].append(item)
        }
        return order.map { LeagueGroup(name: $0, items: map[$0] ?? []) }
    }

    func items(in competition: Competition) -> [EventItem] {
        eventItems.filter { ESPNService.slug(forLeague: $0.event.league) == competition.id }
    }

    var searchResults: [EventItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return eventItems.filter {
            $0.event.title.localizedCaseInsensitiveContains(q)
                || ($0.event.league?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    /// Partidos de la cartelera con un canal de esa marca o de esa competición.
    func items(for filter: MatchFilter) -> [EventItem] {
        switch filter {
        case .competition(let competition):
            return items(in: competition)
        case .channel(let brand):
            let key = Self.brandKey(brand)
            return eventItems.filter { item in
                item.event.channels.contains { Self.brandKey($0.name).contains(key) }
            }
        }
    }

    /// "ESPN 2" → "espn2", "Kerter+" → "kerter": compara marcas sin espacios ni símbolos.
    private static func brandKey(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    func item(forCard card: Channel) -> EventItem? {
        eventItems.first { $0.card.id == card.id }
    }

    /// Canal reproducible para una opción del selector de un partido.
    func channel(for option: EventChannel) -> Channel? {
        if option.id < 0 { return Self.demoChannel(option) }
        return channels.first { $0.id == String(option.id) }
    }

    // MARK: - Carga

    func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false; hasLoaded = true }

        // Independiente de la cartelera del día: se pinta sola cuando llegue.
        if recentMatches.isEmpty { Task { await loadRecentMatches() } }

        if auth.isDemo {
            await loadDemo()
            return
        }
        do {
            channels = try await api.fetchChannels()
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = .current
            let assignments = try await api.fetchAssignments(date: f.string(from: Date()))
            events = LiveEvent.group(assignments)
            await buildEventItems()
        } catch let APIError.http(code, _) where code == 401 {
            auth.signOut()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if eventItems.isEmpty { await loadDemo() }
        }
    }

    /// Construye las tarjetas completas (ESPN, Champions) y las
    /// publica de una sola vez, ya ordenadas: el hero nunca se recoloca
    /// después de aparecer.
    private func buildEventItems() async {
        var items = events.map { event in
            EventItem(event: event, card: Self.baseCard(for: event, preview: previewChannel(for: event)))
        }

        async let championsTask: Void = loadChampionsTeams()

        let infos = await withTaskGroup(of: (Int, ESPNService.MatchInfo?).self) { group in
            for (index, item) in items.enumerated() {
                let event = item.event
                if let sport = event.sport, !Self.isFootball(sport) { continue }
                group.addTask {
                    (index, await ESPNService.find(home: event.home, away: event.away, league: event.league, deep: false))
                }
            }
            var result: [Int: ESPNService.MatchInfo] = [:]
            for await (index, info) in group { if let info { result[index] = info } }
            return result
        }
        for (index, info) in infos { Self.apply(info, to: &items[index].card) }
        await championsTask

        publish(items)
        await preloadFirstHeroCrests()
        // Los que no salieron en su liga se buscan en las demás sin retener el loader.
        let missing = items.indices.filter { infos[$0] == nil }.map { items[$0].event }
        if !missing.isEmpty { Task { await enrichDeep(missing) } }
        // Las portadas llegan solas después: el loader no las espera.
        Task { await loadCovers() }
    }

    private func enrichDeep(_ events: [LiveEvent]) async {
        for event in events {
            if let sport = event.sport, !Self.isFootball(sport) { continue }
            guard let info = await ESPNService.find(home: event.home, away: event.away, league: event.league) else { continue }
            if let index = eventItems.firstIndex(where: { $0.event.id == event.id }) {
                Self.apply(info, to: &eventItems[index].card)
            }
        }
    }

    private func publish(_ items: [EventItem]) {
        eventItems = items
        sortLiveFirst()
    }

    /// Descarga los escudos del primer partido del hero antes de quitar el
    /// loader, para que la portada no salga con los escudos vacíos.
    private func preloadFirstHeroCrests() async {
        guard let first = hero.first else { return }
        let urls = [first.homeLogoURL, first.awayLogoURL].compactMap { $0 }
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask {
                    _ = await ImageDiskCache.shared.image(for: url, target: CGSize(width: 256, height: 256), mode: .fit)
                }
            }
        }
    }

    /// Portada oficial (TheSportsDB) para los partidos del hero. El resto la
    /// pide la ficha al abrirse, para no gastar el límite de la API.
    private func loadCovers() async {
        let targets = hero.filter { $0.heroImageURL == nil }
        let covers = await withTaskGroup(of: (String, URL?).self) { group in
            for card in targets {
                guard let item = item(forCard: card) else { continue }
                group.addTask {
                    (card.id, await MatchArtService.cover(home: item.event.home, away: item.event.away))
                }
            }
            var result: [String: URL] = [:]
            for await (id, url) in group { if let url { result[id] = url } }
            return result
        }
        for (id, url) in covers {
            if let index = eventItems.firstIndex(where: { $0.card.id == id }) {
                eventItems[index].card.heroImageURL = url
            }
        }
    }

    /// Para el autoplay del hero: siempre un Kerter+ si el partido lo tiene,
    /// el de mejor calidad (ver `LiveEvent.previewOption`).
    private func previewChannel(for event: LiveEvent) -> Channel? {
        event.previewOption(resolve: channel(for:)).flatMap(channel(for:))
    }

    private func sortLiveFirst() {
        eventItems = eventItems.enumerated()
            .sorted { a, b in
                let la = a.element.card.isLive ? 0 : 1, lb = b.element.card.isLive ? 0 : 1
                return la != lb ? la < lb : a.offset < b.offset
            }
            .map(\.element)
    }

    // MARK: - Construcción de tarjetas

    private static func baseCard(for event: LiveEvent, preview: Channel?) -> Channel {
        Channel(
            id: "event-\(event.id)",
            name: event.title,
            subtitle: event.league,
            category: event.sport ?? "Fútbol",
            startText: event.time,
            isLive: false,
            isFeatured: true,
            streamURL: preview?.streamURL,
            homeLogoURL: event.homeLogo,
            awayLogoURL: event.awayLogo,
            statusPill: event.time,
            playerType: preview?.playerType,
            drmKeyId: preview?.drmKeyId,
            drmKey: preview?.drmKey
        )
    }

    private static func apply(_ info: ESPNService.MatchInfo, to card: inout Channel) {
        card.homeLogoURL = card.homeLogoURL ?? info.homeLogo
        card.awayLogoURL = card.awayLogoURL ?? info.awayLogo
        card.homeColor = info.homeColor
        card.awayColor = info.awayColor
        card.homeAbbr = info.homeAbbr
        card.awayAbbr = info.awayAbbr
        card.homeScore = info.homeScore
        card.awayScore = info.awayScore
        card.dateLabel = info.dateLabel
        card.venue = info.venue
        card.isLive = info.isLive
        card.isFinal = info.isFinal
        // En vivo/final manda ESPN; por jugar, mantenemos la hora de la cartelera.
        if info.isLive || info.isFinal || (card.statusPill ?? "").isEmpty {
            card.statusPill = info.statusPill
        }
        if (card.startText ?? "").isEmpty { card.startText = info.schedule }
    }

    private static func isFootball(_ sport: String) -> Bool {
        let s = sport.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return s.contains("futbol") || s.contains("soccer") || s.contains("football")
    }

    // MARK: - Partidos recientes

    /// Últimas un par de jornadas terminadas de LaLiga y Champions — el mismo
    /// mecanismo (calendario + `matches(on:)`) que usa el calendario de la
    /// competición, así que no depende de la cartelera del día de Kerter.
    private func loadRecentMatches() async {
        async let laliga = Self.recentFinished(league: "esp.1", name: "LaLiga")
        async let champions = Self.recentFinished(league: "uefa.champions", name: "Champions League")
        let (l, c) = await (laliga, champions)
        recentMatches = (l + c).map { EventItem.highlightsOnly($0.info, league: $0.league) }
    }

    private static func recentFinished(league: String, name: String,
                                       lookback: Int = 2) async -> [(info: ESPNService.MatchInfo, league: String)] {
        let dates = await ESPNService.calendarDates(league: league)
        let today = Calendar(identifier: .gregorian).startOfDay(for: Date())
        let pastDates = dates.filter { $0 <= today }.suffix(lookback)

        var result: [(ESPNService.MatchInfo, String)] = []
        for date in pastDates.reversed() {
            let matches = await ESPNService.matches(league: league, leagueName: name, on: date)
            result.append(contentsOf: matches.filter(\.isFinal).map { ($0, name) })
        }
        return result
    }

    // MARK: - Demo

    /// Sin cuenta: partidos reales de ESPN con canales de prueba (stream de Apple).
    private func loadDemo() async {
        channels = DemoData.channels
        async let laliga = ESPNService.matches(league: "esp.1", leagueName: "LaLiga")
        async let champions = ESPNService.matches(league: "uefa.champions", leagueName: "Champions League")
        async let premier = ESPNService.matches(league: "eng.1", leagueName: "Premier League")
        async let championsTable: Void = loadChampionsTeams()
        let infos = await Array(laliga.prefix(6)) + Array(champions.prefix(6)) + Array(premier.prefix(6))
        await championsTable

        let options = [
            EventChannel(id: -1, name: "Kerter+ 1", logo: nil),
            EventChannel(id: -2, name: "Kerter+ 2", logo: nil),
            EventChannel(id: -3, name: "Kerter+ 4K", logo: nil),
        ]
        events = infos.map { info in
            LiveEvent(id: "demo-\(info.id)", home: info.home, away: info.away,
                      league: info.league, sport: "Fútbol", time: nil,
                      homeLogo: info.homeLogo, awayLogo: info.awayLogo, channels: options)
        }
        publish(zip(events, infos).map { event, info in
            var card = Self.baseCard(for: event, preview: Self.demoChannel(options[0]))
            Self.apply(info, to: &card)
            return EventItem(event: event, card: card)
        })
        await preloadFirstHeroCrests()
        // Las portadas llegan solas después: el loader no las espera.
        Task { await loadCovers() }
    }

    private static func demoChannel(_ option: EventChannel) -> Channel {
        Channel(id: "demo-channel-\(-option.id)", name: option.name, category: "Fútbol",
                isLive: true, streamURL: AppConfig.demoStreamURL)
    }
}
