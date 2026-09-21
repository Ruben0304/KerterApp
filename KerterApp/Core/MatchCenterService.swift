import Foundation
import CoreGraphics

/// Centro del partido: alineaciones con foto real de cada jugador, su posición
/// exacta sobre el campo, su nota, y las estadísticas del encuentro
/// (posesión, goles esperados, ocasiones claras, remates…).
///
/// ESPN no publica fotos de futbolistas —el `headshot` del roster viene vacío
/// en todas las ligas de fútbol—, así que las alineaciones se piden a la API
/// pública de 365Scores, que sí trae retrato, nota, posición en la cancha y
/// el cuadro de estadísticas ya calculado (incluido xG) y además en español.
enum MatchCenterService {

    // MARK: - Modelo

    /// Un jugador colocado en el campo, con lo que se pinta sobre su ficha.
    struct Player: Identifiable, Sendable, Hashable {
        let id: String
        let name: String
        let shortName: String
        let jersey: String?
        let position: String?
        let photo: URL?
        /// Nota del partido (5,8 · 7,2…). `nil` mientras no haya.
        let rating: Double?
        /// 0 = banda izquierda, 1 = banda derecha (visto por el espectador).
        let x: CGFloat
        /// 0 = línea de meta propia, 1 = medio campo.
        let y: CGFloat
        let goals: Int
        let yellowCards: Int
        let redCards: Int
        /// Minuto en que salió / entró al campo, si hubo cambio.
        let subbedOut: Int?
        let subbedIn: Int?
    }

    struct TeamLineup: Sendable, Hashable {
        let formation: String?
        let starters: [Player]
        let bench: [Player]
        let coach: String?
        var isPlayable: Bool { starters.count >= 7 }
    }

    /// Una fila del cuadro de estadísticas: el mismo dato para los dos equipos
    /// y qué parte de la barra le toca a cada uno.
    struct StatRow: Identifiable, Sendable, Hashable {
        let id: Int
        let name: String
        let home: String
        let away: String
        /// 0…1 — la porción de barra del local (el visitante es el resto).
        let homeShare: Double
        /// Las cuatro o cinco de cabecera (posesión, xG, remates…).
        let isMajor: Bool
        var awayShare: Double { 1 - homeShare }
    }

    struct MatchCenter: Sendable, Hashable {
        let home: TeamLineup?
        let away: TeamLineup?
        let stats: [StatRow]
        /// "45'", "Medio tiempo", "Finalizado"…
        let statusText: String?
        let isLive: Bool

        var hasLineups: Bool { (home?.isPlayable ?? false) && (away?.isPlayable ?? false) }
        var hasStats: Bool { !stats.isEmpty }
        var isEmpty: Bool { !hasLineups && !hasStats }
    }

    // MARK: - Carga

    /// Busca el partido por nombres de equipo y devuelve alineaciones +
    /// estadísticas. `nil` si no se encuentra o no hay nada publicado.
    static func load(home: String, away: String, league: String?) async -> MatchCenter? {
        guard let gameID = await gameID(home: home, away: away, league: league) else { return nil }
        return await CenterCache.shared.center(gameID) { await fetchCenter(gameID: gameID) }
    }

    private static func fetchCenter(gameID: Int) async -> MatchCenter? {
        async let detail = get(GameFeed.self, path: "game/", query: ["gameId": String(gameID)])
        async let statsFeed = get(StatsFeed.self, path: "game/stats/", query: ["games": String(gameID)])

        guard let game = await detail?.game else { return nil }

        let homeID = game.homeCompetitor?.id
        let awayID = game.awayCompetitor?.id
        var byMember: [Int: GameFeed.Member] = [:]
        for m in game.members ?? [] { byMember[m.id] = m }

        let events = game.events ?? []
        let home = lineup(game.homeCompetitor, members: byMember, events: events)
        let away = lineup(game.awayCompetitor, members: byMember, events: events)
        let stats = rows(await statsFeed?.statistics ?? [], homeID: homeID, awayID: awayID)

        let center = MatchCenter(home: home, away: away, stats: stats,
                                 statusText: game.statusText,
                                 isLive: game.statusGroup == 3)
        return center.isEmpty ? nil : center
    }

    // MARK: - Alineación

    private static func lineup(_ competitor: GameFeed.Competitor?,
                               members: [Int: GameFeed.Member],
                               events: [GameFeed.Event]) -> TeamLineup? {
        guard let competitor, let lineups = competitor.lineups else { return nil }
        let entries = lineups.members ?? []
        guard !entries.isEmpty else { return nil }

        var starters: [Player] = []
        var bench: [Player] = []
        var coach: String?

        for entry in entries {
            let info = members[entry.id]
            switch entry.status {
            case 1:
                starters.append(player(entry, info: info, events: events, onPitch: true))
            case 2:
                bench.append(player(entry, info: info, events: events, onPitch: false))
            case 4:
                coach = info?.name
            default:
                break
            }
        }
        guard !starters.isEmpty else { return nil }
        return TeamLineup(formation: lineups.formation, starters: starters, bench: bench, coach: coach)
    }

    private static func player(_ entry: GameFeed.LineupMember,
                               info: GameFeed.Member?,
                               events: [GameFeed.Event],
                               onPitch: Bool) -> Player {
        let mine = events.filter { $0.playerId == entry.id }
        let jersey = info?.jerseyNumber.map(String.init)
        let full = info?.name ?? "—"

        // 365Scores da la posición en porcentajes: 0 = línea de meta propia y
        // 100 = campo contrario; 0 = izquierda y 100 = derecha. Se deja aire
        // en los bordes para que la ficha no se salga del césped.
        let line = CGFloat(entry.yardFormation?.fieldLine ?? 50) / 100
        let side = CGFloat(entry.yardFormation?.fieldSide ?? 50) / 100

        return Player(
            id: String(entry.id),
            name: full,
            shortName: info?.shortName ?? full,
            jersey: jersey,
            position: entry.position?.name,
            photo: info?.athleteId.flatMap(photoURL),
            rating: (entry.ranking ?? -1) > 0 ? entry.ranking : nil,
            x: onPitch ? 0.10 + side * 0.80 : 0.5,
            y: onPitch ? 0.105 + line * 0.80 : 0,
            goals: mine.filter { $0.eventType?.id == 1 }.count,
            yellowCards: mine.filter { $0.eventType?.id == 2 }.count,
            redCards: mine.filter { $0.eventType?.id == 3 }.count,
            subbedOut: events.first { $0.eventType?.id == 1000 && $0.extraPlayers?.contains(entry.id) == true }
                .flatMap { $0.gameTime.map { Int($0) } },
            subbedIn: mine.first { $0.eventType?.id == 1000 }.flatMap { $0.gameTime.map { Int($0) } }
        )
    }

    /// Retrato recortado a la cara y ya redondeado por el CDN.
    private static func photoURL(_ athleteID: Int) -> URL? {
        URL(string: "https://imagecache.365scores.com/image/upload/"
            + "f_png,w_160,h_160,c_limit,q_auto:eco,dpr_2,"
            + "d_Athletes:default1.png,r_max,c_thumb,g_face,z_0.65/v3/Athletes/\(athleteID)")
    }

    // MARK: - Estadísticas

    /// Lo que se ve sin desplegar: posesión, goles esperados, ocasiones
    /// claras, remates, remates a puerta y córners.
    private static let headlineStats: Set<Int> = [10, 76, 24, 3, 4, 8]

    /// Las estadísticas vienen en una lista plana, una entrada por equipo.
    /// Se emparejan por `id` y se ordenan como las publica 365Scores.
    private static func rows(_ raw: [StatsFeed.Stat], homeID: Int?, awayID: Int?) -> [StatRow] {
        var byID: [Int: (home: StatsFeed.Stat?, away: StatsFeed.Stat?, order: Int)] = [:]
        for stat in raw {
            let order = stat.order ?? 999
            var slot = byID[stat.id] ?? (nil, nil, order)
            slot.order = min(slot.order, order)
            if stat.competitorId == homeID { slot.home = stat }
            if stat.competitorId == awayID { slot.away = stat }
            byID[stat.id] = slot
        }

        return byID.compactMap { id, slot -> (StatRow, Int)? in
            guard let home = slot.home, let away = slot.away,
                  let hv = home.value, let av = away.value else { return nil }
            // Si la API no da reparto (o los dos van a cero) la barra se
            // divide a medias en vez de quedarse en blanco.
            let hp = home.valuePercentage ?? 0
            let ap = away.valuePercentage ?? 0
            let share = hp + ap > 0 ? hp / (hp + ap) : 0.5
            return (StatRow(id: id, name: home.name ?? "", home: hv, away: av,
                            homeShare: share,
                            isMajor: home.isMajor ?? false || headlineStats.contains(id)),
                    slot.order)
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
    }

    // MARK: - Localizar el partido

    /// Slug de competición de ESPN → id de 365Scores.
    private static let competitionIDs: [String: Int] = [
        "uefa.champions": 572, "esp.1": 11, "eng.1": 7, "esp.copa_del_rey": 13,
        "uefa.europa": 573, "uefa.europa.conf": 7685, "ita.1": 17, "ger.1": 25,
        "fra.1": 35, "esp.super_cup": 15, "eng.fa": 8, "conmebol.libertadores": 102,
        "fifa.cwc": 5096, "fifa.world": 5930, "mex.1": 141, "usa.1": 104,
        "por.1": 73, "ned.1": 57, "arg.1": 72, "bra.1": 113,
    ]

    private static func gameID(home: String, away: String, league: String?) async -> Int? {
        let ids: [Int]
        if let slug = ESPNService.slug(forLeague: league), let id = competitionIDs[slug] {
            ids = [id]
        } else if home.isEmpty && away.isEmpty {
            return nil
        } else {
            ids = Array(competitionIDs.values).sorted()
        }

        let key = ids.map(String.init).joined(separator: ",")
        let games = await ScheduleCache.shared.games(key) { await fetchGames(competitions: key) }
        // El backend titula a veces "Visitante at Local", así que vale el par
        // en cualquier orden.
        return games.first {
            (ESPNService.similar($0.home, home) && ESPNService.similar($0.away, away))
                || (ESPNService.similar($0.home, away) && ESPNService.similar($0.away, home))
        }?.id
    }

    struct GameRef: Sendable, Hashable {
        let id: Int
        let home: String
        let away: String
    }

    // MARK: - Respaldo con ESPN

    /// Si 365Scores no tiene el partido (liga fuera de su catálogo, nombres
    /// que no casan), se pintan las alineaciones de ESPN en el mismo campo.
    /// No hay retrato ni nota, y la posición se deduce de la formación.
    static func fallback(_ lineups: ESPNService.Lineups) -> MatchCenter? {
        func convertTeam(_ team: ESPNService.TeamLineup?) -> TeamLineup? {
            guard let team, !team.starters.isEmpty else { return nil }
            let placed = grid(formation: team.formation, count: team.starters.count)
            let starters = zip(team.starters, placed).map { player, spot in
                convert(player, x: spot.x, y: spot.y)
            }
            return TeamLineup(formation: team.formation,
                              starters: starters,
                              bench: team.substitutes.map { convert($0, x: 0.5, y: 0) },
                              coach: nil)
        }

        let home = convertTeam(lineups.home)
        let away = convertTeam(lineups.away)
        guard home != nil || away != nil else { return nil }
        return MatchCenter(home: home, away: away, stats: [], statusText: nil, isLive: false)
    }

    private static func convert(_ player: ESPNService.LineupPlayer, x: CGFloat, y: CGFloat) -> Player {
        // "Kylian Mbappé" → "Mbappé": en la cancha solo cabe el apellido.
        let short = player.name.split(separator: " ").last.map(String.init) ?? player.name
        return Player(id: player.id, name: player.name, shortName: short,
                      jersey: player.jersey, position: player.position,
                      photo: nil, rating: nil, x: x, y: y,
                      goals: 0, yellowCards: 0, redCards: 0, subbedOut: nil, subbedIn: nil)
    }

    /// Portero en su línea de meta y el resto repartido en las líneas de la
    /// formación ("4-3-3" → 4, 3, 3) hacia el centro del campo.
    private static func grid(formation: String?, count: Int) -> [(x: CGFloat, y: CGFloat)] {
        guard count > 0 else { return [] }
        let outfield = count - 1
        var lines = (formation?.split(separator: "-").compactMap { Int($0) }) ?? []
        if lines.isEmpty || lines.reduce(0, +) != outfield {
            let defenders = Int((Double(outfield) * 0.4).rounded())
            let forwards = max(1, Int((Double(outfield) * 0.27).rounded()))
            lines = [defenders, max(0, outfield - defenders - forwards), forwards].filter { $0 > 0 }
        }

        var spots: [(x: CGFloat, y: CGFloat)] = [(0.5, 0.105)]
        for (i, size) in lines.enumerated() where size > 0 {
            let y = 0.105 + (CGFloat(i) + 1) * (0.80 / CGFloat(lines.count + 1))
            for slot in 0..<size {
                let x: CGFloat = size == 1 ? 0.5 : 0.10 + CGFloat(slot) * (0.80 / CGFloat(size - 1))
                spots.append((x, y))
            }
        }
        // Si la formación describe menos jugadores de los que hay, los que
        // sobren se apilan en el centro antes que quedarse sin sitio.
        while spots.count < count { spots.append((0.5, 0.5)) }
        return Array(spots.prefix(count))
    }

    private static func fetchGames(competitions: String) async -> [GameRef] {
        let day = DateFormatter()
        day.dateFormat = "dd/MM/yyyy"
        let cal = Calendar.current
        let from = cal.date(byAdding: .day, value: -2, to: Date()) ?? Date()
        let to = cal.date(byAdding: .day, value: 2, to: Date()) ?? Date()

        let feed = await get(ScheduleFeed.self, path: "games/allscores/", query: [
            "competitions": competitions,
            "startDate": day.string(from: from),
            "endDate": day.string(from: to),
            "showOdds": "false",
        ])
        return (feed?.games ?? []).compactMap {
            guard let h = $0.homeCompetitor?.name, let a = $0.awayCompetitor?.name else { return nil }
            return GameRef(id: $0.id, home: h, away: a)
        }
    }

    // MARK: - Red

    private static func get<T: Decodable>(_ type: T.Type, path: String,
                                          query: [String: String]) async -> T? {
        var comps = URLComponents(string: "https://webws.365scores.com/web/\(path)")
        var items = [
            URLQueryItem(name: "appTypeId", value: "5"),
            URLQueryItem(name: "langId", value: "29"),          // español
            URLQueryItem(name: "timezoneName", value: TimeZone.current.identifier),
            URLQueryItem(name: "userCountryId", value: "6"),
        ]
        items += query.map { URLQueryItem(name: $0.key, value: $0.value) }
        comps?.queryItems = items
        guard let url = comps?.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - JSON

    private struct ScheduleFeed: Decodable {
        let games: [Game]?
        struct Game: Decodable {
            let id: Int
            let homeCompetitor: Side?
            let awayCompetitor: Side?
            struct Side: Decodable { let name: String? }
        }
    }

    private struct GameFeed: Decodable {
        let game: Game?
        struct Game: Decodable {
            let statusText: String?
            let statusGroup: Int?
            let homeCompetitor: Competitor?
            let awayCompetitor: Competitor?
            let members: [Member]?
            let events: [Event]?
        }
        struct Competitor: Decodable {
            let id: Int?
            let lineups: Lineups?
        }
        struct Lineups: Decodable {
            let formation: String?
            let members: [LineupMember]?
        }
        struct LineupMember: Decodable {
            let id: Int
            /// 1 titular · 2 suplente · 3 ausente · 4 cuerpo técnico.
            let status: Int?
            let position: Position?
            let yardFormation: Yard?
            let ranking: Double?
            struct Position: Decodable { let name: String? }
            struct Yard: Decodable {
                let fieldLine: Int?
                let fieldSide: Int?
            }
        }
        struct Member: Decodable {
            let id: Int
            let athleteId: Int?
            let name: String?
            let shortName: String?
            let jerseyNumber: Int?
        }
        struct Event: Decodable {
            let playerId: Int?
            let gameTime: Double?
            let extraPlayers: [Int]?
            let eventType: EventType?
            struct EventType: Decodable { let id: Int? }
        }
    }

    private struct StatsFeed: Decodable {
        let statistics: [Stat]?
        struct Stat: Decodable {
            let id: Int
            let name: String?
            let competitorId: Int?
            let value: String?
            let valuePercentage: Double?
            let isMajor: Bool?
            let order: Int?
        }
    }
}

// MARK: - Cachés

/// El calendario cambia poco: 5 minutos, y las peticiones simultáneas a la
/// misma lista de competiciones comparten una sola llamada.
private actor ScheduleCache {
    static let shared = ScheduleCache()
    private var store: [String: (date: Date, games: [MatchCenterService.GameRef])] = [:]
    private var inFlight: [String: Task<[MatchCenterService.GameRef], Never>] = [:]

    func games(_ key: String,
               loader: @escaping @Sendable () async -> [MatchCenterService.GameRef]) async -> [MatchCenterService.GameRef] {
        if let hit = store[key], Date().timeIntervalSince(hit.date) < 300 { return hit.games }
        if let running = inFlight[key] { return await running.value }
        let task = Task { await loader() }
        inFlight[key] = task
        let fresh = await task.value
        inFlight[key] = nil
        if !fresh.isEmpty { store[key] = (Date(), fresh) }
        return fresh
    }
}

/// Alineaciones y estadísticas: 30 segundos, porque en vivo cambian a cada rato.
private actor CenterCache {
    static let shared = CenterCache()
    private var store: [Int: (date: Date, center: MatchCenterService.MatchCenter?)] = [:]

    func center(_ gameID: Int,
                loader: @Sendable () async -> MatchCenterService.MatchCenter?) async -> MatchCenterService.MatchCenter? {
        if let hit = store[gameID], Date().timeIntervalSince(hit.date) < 30 { return hit.center }
        let fresh = await loader()
        store[gameID] = (Date(), fresh)
        return fresh
    }
}
