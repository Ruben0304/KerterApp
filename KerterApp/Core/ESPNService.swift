import Foundation

/// Trae partidos reales (escudos oficiales, colores, marcador y recortes HD de
/// jugadores) desde la API pública de ESPN — la misma fuente que usa la app
/// original de Kerter. No requiere autenticación.
enum ESPNService {

    /// Un partido tal cual lo publica ESPN, a nivel de equipo.
    struct MatchInfo: Sendable, Hashable {
        let id: String
        let league: String
        let home: String
        let away: String
        let homeId: String?
        let awayId: String?
        let homeLogo: URL?
        let awayLogo: URL?
        let homeColor: String?
        let awayColor: String?
        let homeAbbr: String?
        let awayAbbr: String?
        let homeScore: String?
        let awayScore: String?
        let statusPill: String
        let dateLabel: String?
        let schedule: String?
        let isLive: Bool
        let isFinal: Bool
        let venue: String?
        /// Fecha real del partido — para ordenar cronológicamente (los demás
        /// campos de fecha ya vienen formateados para mostrar, no para ordenar).
        let date: Date?
    }

    // MARK: - Decodificación del feed

    private struct Feed: Decodable {
        let events: [Event]
        struct Event: Decodable {
            let id: String
            let date: String?
            let competitions: [Competition]?
        }
        struct Competition: Decodable {
            let competitors: [Competitor]?
            let status: Status?
            let venue: Venue?
            struct Venue: Decodable {
                let fullName: String?
                let address: Address?
                struct Address: Decodable { let city: String? }
            }
        }
        struct Competitor: Decodable {
            let homeAway: String?
            let team: Team?
            let score: String?

            // El "scoreboard" manda `score` como texto plano, pero el
            // calendario de un equipo ("teams/{id}/schedule") lo manda como
            // objeto ({"displayValue": "2", ...}) — aceptamos ambos.
            enum CodingKeys: String, CodingKey { case homeAway, team, score }
            struct ScoreObject: Decodable { let displayValue: String? }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                homeAway = try c.decodeIfPresent(String.self, forKey: .homeAway)
                team = try c.decodeIfPresent(Team.self, forKey: .team)
                if let s = try? c.decode(String.self, forKey: .score) {
                    score = s
                } else {
                    score = (try? c.decode(ScoreObject.self, forKey: .score))?.displayValue
                }
            }
        }
        struct Team: Decodable {
            let id: String?
            let displayName: String?
            let shortDisplayName: String?
            let abbreviation: String?
            let logo: String?
            let color: String?
            let alternateColor: String?
        }
        struct Status: Decodable {
            let type: StatusType?
            struct StatusType: Decodable {
                let state: String?
                let shortDetail: String?
                let completed: Bool?
            }
        }
    }

    // MARK: - Partidos de una liga

    /// `league` p. ej. "conmebol.libertadores", "esp.1", "eng.1", "uefa.champions".
    static func matches(league: String, leagueName: String) async -> [MatchInfo] {
        guard let url = URL(string:
            "https://site.api.espn.com/apis/site/v2/sports/soccer/\(league)/scoreboard") else { return [] }
        // Un fallo puntual de red o un 429/5xx de ESPN no debe dejar la home sin escudos.
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(600 * attempt)) }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let feed = try? JSONDecoder().decode(Feed.self, from: data) else { continue }
            return matchInfos(from: feed, leagueName: leagueName)
        }
        return []
    }

    private static func matchInfos(from feed: Feed, leagueName: String) -> [MatchInfo] {
        feed.events.compactMap { event in
            guard let comp = event.competitions?.first,
                  let competitors = comp.competitors, competitors.count >= 2 else { return nil }
            let home = competitors.first { $0.homeAway == "home" } ?? competitors.first
            let away = competitors.first { $0.homeAway == "away" } ?? competitors.last
            let state = comp.status?.type?.state
            let isLive = (state == "in")
            let isFinal = (comp.status?.type?.completed ?? false) || state == "post"

            // Píldora superior de la tarjeta, como en Apple TV.
            let pill: String
            if isFinal {
                pill = "Final"
            } else if isLive {
                pill = comp.status?.type?.shortDetail ?? "En vivo"
            } else {
                pill = text(event.date, format: "EEE h:mm a")?.capitalized ?? "Próximamente"
            }

            return MatchInfo(
                id: event.id,
                league: leagueName,
                home: home?.team?.shortDisplayName ?? home?.team?.displayName ?? "Local",
                away: away?.team?.shortDisplayName ?? away?.team?.displayName ?? "Visitante",
                homeId: home?.team?.id,
                awayId: away?.team?.id,
                homeLogo: teamLogo(home?.team),
                awayLogo: teamLogo(away?.team),
                homeColor: teamHex(home?.team),
                awayColor: teamHex(away?.team),
                homeAbbr: home?.team?.abbreviation,
                awayAbbr: away?.team?.abbreviation,
                homeScore: home?.score,
                awayScore: away?.score,
                statusPill: pill,
                dateLabel: text(event.date, format: "d MMM"),
                schedule: comp.status?.type?.shortDetail ?? friendlyDate(event.date),
                isLive: isLive,
                isFinal: isFinal,
                venue: venueLabel(comp.venue),
                // `isoFormatter` (ISO8601DateFormatter por defecto) exige
                // segundos y ESPN los omite ("...T16:45Z"): usamos el mismo
                // parser de repuesto que ya tenía `calendarDates`.
                date: event.date.flatMap(parseCalendarDate)
            )
        }
    }

    /// Partidos de una liga en una fecha concreta (calendario). Sin `date`,
    /// ESPN devuelve la jornada de hoy — igual que `matches(league:leagueName:)`.
    static func matches(league: String, leagueName: String, on date: Date) async -> [MatchInfo] {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        df.timeZone = TimeZone(identifier: "UTC")
        guard let url = URL(string:
            "https://site.api.espn.com/apis/site/v2/sports/soccer/\(league)/scoreboard?dates=\(df.string(from: date))")
        else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let feed = try? JSONDecoder().decode(Feed.self, from: data) else { return [] }
        return matchInfos(from: feed, leagueName: leagueName)
    }

    /// Días de toda la temporada en los que la competición tiene partidos
    /// (jornadas), tal como los publica ESPN — para el selector del calendario.
    static func calendarDates(league: String) async -> [Date] {
        guard let url = URL(string:
            "https://site.api.espn.com/apis/site/v2/sports/soccer/\(league)/scoreboard") else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let leagues = obj["leagues"] as? [[String: Any]],
              let calendar = leagues.first?["calendar"] as? [String] else { return [] }
        return calendar.compactMap(parseCalendarDate).sorted()
    }

    /// "2026-08-15T07:00Z" — sin segundos, así que `ISO8601DateFormatter` por
    /// defecto no lo parsea; probamos ese formato exacto.
    private static func parseCalendarDate(_ s: String) -> Date? {
        if let d = isoFormatter.date(from: s) { return d }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        return df.date(from: s)
    }

    /// Partidos de una liga ya convertidos a `Channel` (rieles y buscador).
    static func soccer(league: String, leagueName: String) async -> [Channel] {
        let infos = await matches(league: league, leagueName: leagueName)
        var result = infos.map { channel(from: $0, league: leagueName) }

        // Los partidos EN VIVO lideran el hero (fondo de estadio + escudos).
        // Si no hay ninguno en vivo, destacamos el primero.
        let hasLive = result.contains { $0.isLive }
        var enriched = 0
        for i in infos.indices {
            let featured = result[i].isLive || (!hasLive && i == 0)
            guard featured else { continue }
            result[i].isFeatured = true
            // A los primeros destacados les añadimos recortes HD de jugadores.
            // Solo a dos: cada uno cuesta dos peticiones de plantilla y dos PNG grandes.
            if enriched < 2, let hId = infos[i].homeId, let aId = infos[i].awayId {
                async let homePlayer = headshot(league: league, teamId: hId)
                async let awayPlayer = headshot(league: league, teamId: aId)
                let (hp, ap) = await (homePlayer, awayPlayer)
                result[i].homePlayerURL = hp
                result[i].awayPlayerURL = ap
                enriched += 1
            }
        }
        return result
    }

    static func channel(from info: MatchInfo, league: String) -> Channel {
        var channel = Channel(
            id: "espn-\(info.id)",
            name: "\(info.home) vs \(info.away)",
            subtitle: league,
            category: "Fútbol",
            startText: info.schedule,
            isLive: info.isLive,
            isFeatured: false,
            streamURL: info.isLive ? AppConfig.demoStreamURL : nil,
            homeLogoURL: info.homeLogo,
            awayLogoURL: info.awayLogo,
            homeColor: info.homeColor,
            awayColor: info.awayColor,
            homeAbbr: info.homeAbbr,
            awayAbbr: info.awayAbbr,
            homeScore: info.homeScore,
            awayScore: info.awayScore,
            statusPill: info.statusPill,
            dateLabel: info.dateLabel,
            isFinal: info.isFinal
        )
        channel.venue = info.venue
        return channel
    }

    // MARK: - Buscar un partido concreto (cartelera de Kerter → datos de ESPN)

    /// Ligas donde buscar cuando el backend no dice de cuál es el partido.
    private static let fallbackSlugs = ["esp.1", "eng.1", "uefa.champions",
                                        "ita.1", "ger.1", "fra.1", "uefa.nations"]

    /// Busca en ESPN el partido "local vs visitante" para robarle escudos,
    /// colores y marcador. `league` es el texto que da el backend de Kerter.
    /// `deep: false` mira solo la liga que dice el backend (rápido, para no
    /// retener el loader); con `true` prueba además en las demás ligas.
    static func find(home: String, away: String, league: String?, deep: Bool = true) async -> MatchInfo? {
        if home.isEmpty && away.isEmpty { return nil }
        // La liga que dice el backend primero; si ahí no aparece (nombre
        // ambiguo o competición distinta), se prueba en las demás.
        var slugs = fallbackSlugs
        if let slug = slug(forLeague: league) {
            slugs.removeAll { $0 == slug }
            slugs.insert(slug, at: 0)
            if !deep { slugs = [slug] }
        } else if !deep {
            return nil
        }

        // Ayer–mañana: el "hoy" de ESPN va en su zona horaria y un partido de
        // la noche puede caer en el día de al lado.
        var partial: [MatchInfo] = []
        for slug in slugs {
            let name = Competition.featured.first { $0.id == slug }?.name ?? (league ?? "Fútbol")
            let list = await ScoreboardCache.shared.matches(slug) {
                await matchesAroundToday(league: slug, leagueName: name)
            }
            if let hit = list.first(where: { pairs($0, home: home, away: away) }) { return hit }
            partial += list.filter { pairsLoosely($0, home: home, away: away) }
        }
        // Nombres que el backend escribe distinto ("Inter Milan", "Nottm Forest"):
        // si un equipo coincide y solo hay un partido así, es ese.
        let result = Set(partial.map(\.id)).count == 1 ? partial.first : nil
        #if DEBUG
        if result == nil {
            let line = "sin coincidencia: \(home) vs \(away) · liga \(league ?? "-") · deep \(deep)\n"
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("espn-debug.log")
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? line.write(to: url, atomically: true, encoding: .utf8) }
        }
        #endif
        return result
    }

    /// Hoy (como lo ve ESPN) más ayer y mañana, en paralelo. El endpoint no
    /// admite rangos de fechas, solo un día por petición.
    private static func matchesAroundToday(league: String, leagueName: String) async -> [MatchInfo] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date()).addingTimeInterval(12 * 3600)  // mediodía: el formato de fecha va en UTC
        let days = [-1, 1].compactMap { cal.date(byAdding: .day, value: $0, to: today) }
        async let base = matches(league: league, leagueName: leagueName)
        let extra = await withTaskGroup(of: [MatchInfo].self) { group in
            for day in days { group.addTask { await matches(league: league, leagueName: leagueName, on: day) } }
            var all: [MatchInfo] = []
            for await list in group { all += list }
            return all
        }
        let baseList = await base
        let known = Set(baseList.map(\.id))
        return baseList + extra.filter { !known.contains($0.id) }
    }

    /// Traduce el nombre de liga del backend ("LaLiga", "Champions") al slug de ESPN.
    static func slug(forLeague name: String?) -> String? {
        guard let raw = name, !raw.isEmpty else { return nil }
        let n = normalize(raw)
        let table: [(String, String)] = [
            // Antes que "naciones" y "champions": "Liga de Naciones Concacaf".
            ("naciones concacaf", "concacaf.nations.league"), ("concacaf nations", "concacaf.nations.league"),
            ("champions", "uefa.champions"), ("conference", "uefa.europa.conf"),
            ("nations league", "uefa.nations"), ("liga de naciones", "uefa.nations"),
            ("europa", "uefa.europa"), ("copa del rey", "esp.copa_del_rey"),
            ("supercopa", "esp.super_cup"), ("laliga", "esp.1"), ("la liga", "esp.1"),
            ("espana", "esp.1"), ("premier", "eng.1"), ("fa cup", "eng.fa"),
            ("serie a", "ita.1"), ("italia", "ita.1"), ("bundesliga", "ger.1"),
            ("alemania", "ger.1"), ("ligue 1", "fra.1"), ("francia", "fra.1"),
            ("libertadores", "conmebol.libertadores"), ("mundial de clubes", "fifa.cwc"),
            ("mundial", "fifa.world"), ("liga mx", "mex.1"), ("mexico", "mex.1"),
            ("mls", "usa.1"), ("portugal", "por.1"), ("eredivisie", "ned.1"),
            ("holanda", "ned.1"), ("argentina", "arg.1"), ("brasil", "bra.1"),
        ]
        return table.first { n.contains($0.0) }?.1
    }

    // MARK: - Comparación de nombres de equipo

    /// Sin acentos, en minúsculas y sin sufijos de club ("Atlético FC" → "atletico").
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive],
                               locale: Locale(identifier: "es"))
        var out = folded.replacingOccurrences(of: "[^a-z0-9 ]", with: " ",
                                              options: .regularExpression)
        for noise in [" fc", "fc ", " cf", "cf ", " sc", " ac", " club", " de futbol", " futbol"] {
            out = out.replacingOccurrences(of: noise, with: " ")
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    /// Compara dos nombres de equipo ignorando acentos, mayúsculas y sufijos
    /// de club — también útil fuera de este archivo (p. ej. para priorizar
    /// el hero por equipo, sin depender del formato exacto del backend).
    static func similar(_ a: String, _ b: String) -> Bool {
        // Selecciones: "Francia" (Kerter) y "France" (ESPN) son la misma si
        // comparten código FIFA; y "Irlanda" no es "Irlanda del Norte".
        if let codeA = FIFARanking.code(for: a), let codeB = FIFARanking.code(for: b) { return codeA == codeB }
        let x = normalize(a), y = normalize(b)
        guard x.count > 2, y.count > 2 else { return false }
        return x == y || x.contains(y) || y.contains(x)
    }

    /// Nombre parecido por prefijo de la primera palabra ("inter" ↔ "internazionale").
    private static func looselySimilar(_ a: String, _ b: String) -> Bool {
        if similar(a, b) { return true }
        let wa = normalize(a).split(separator: " ").map(String.init)
        let wb = normalize(b).split(separator: " ").map(String.init)
        // Uno de los dos de una sola palabra: si no, "Real Madrid" casaría con "Real Sociedad".
        guard let x = wa.first, let y = wb.first, min(x.count, y.count) >= 4,
              wa.count == 1 || wb.count == 1 else { return false }
        return x.hasPrefix(y) || y.hasPrefix(x)
    }

    /// Basta con que coincida un equipo: para nombres distintos entre backend y ESPN.
    private static func pairsLoosely(_ info: MatchInfo, home: String, away: String) -> Bool {
        [home, away].contains { name in
            looselySimilar(info.home, name) || looselySimilar(info.away, name)
        }
    }

    /// El backend titula "Visitante at Local", así que probamos también al revés.
    private static func pairs(_ info: MatchInfo, home: String, away: String) -> Bool {
        (similar(info.home, home) && similar(info.away, away))
            || (similar(info.home, away) && similar(info.away, home))
    }

    // MARK: - Alineaciones

    /// Un jugador dentro de la alineación de un partido concreto.
    struct LineupPlayer: Sendable, Hashable, Identifiable {
        let id: String
        let name: String
        let jersey: String?
        let position: String?
        let headshot: URL?
        let isStarter: Bool
    }

    /// Alineación de un equipo: titulares + suplentes, con su formación.
    struct TeamLineup: Sendable, Hashable {
        let formation: String?
        let starters: [LineupPlayer]
        let substitutes: [LineupPlayer]
    }

    /// Alineaciones de ambos equipos para un partido. ESPN solo las publica
    /// (confirmadas) cerca de la hora de inicio; antes puede no haber nada.
    struct Lineups: Sendable, Hashable {
        let home: TeamLineup?
        let away: TeamLineup?
        var isAvailable: Bool { home != nil || away != nil }
    }

    struct MatchDetails: Sendable, Hashable {
        let lineups: Lineups?
    }

    private struct SummaryFeed: Decodable {
        let rosters: [RosterTeam]?

        struct RosterTeam: Decodable {
            let homeAway: String?
            let formation: String?
            let team: Team?
            let roster: [RosterEntry]?
            struct Team: Decodable { let id: String? }
        }
        struct RosterEntry: Decodable {
            let starter: Bool?
            let jersey: String?
            let position: Position?
            let athlete: Athlete?
            struct Position: Decodable { let abbreviation: String? }
            struct Athlete: Decodable {
                let id: String?
                let displayName: String?
                let headshot: Headshot?
                struct Headshot: Decodable { let href: String? }
            }
        }
    }

    /// Busca el partido "local vs visitante" y trae sus alineaciones.
    static func matchDetails(home: String, away: String, league: String?) async -> MatchDetails? {
        let slugs: [String]
        if let slug = slug(forLeague: league) {
            slugs = [slug]
        } else if home.isEmpty && away.isEmpty {
            return nil
        } else {
            slugs = fallbackSlugs
        }

        for slug in slugs {
            let name = Competition.featured.first { $0.id == slug }?.name ?? (league ?? "Fútbol")
            let list = await ScoreboardCache.shared.matches(slug) {
                await matches(league: slug, leagueName: name)
            }
            guard let hit = list.first(where: { pairs($0, home: home, away: away) }) else { continue }
            return await MatchDetailsCache.shared.details(hit.id) {
                await fetchMatchDetails(league: slug, matchInfo: hit)
            }
        }
        return nil
    }

    private static func fetchMatchDetails(league: String, matchInfo: MatchInfo) async -> MatchDetails? {
        guard let url = URL(string:
            "https://site.api.espn.com/apis/site/v2/sports/soccer/\(league)/summary?event=\(matchInfo.id)&lang=es")
        else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let feed = try? JSONDecoder().decode(SummaryFeed.self, from: data) else { return nil }

        func team(isHome: Bool) -> TeamLineup? {
            let entry = feed.rosters?.first {
                if let ha = $0.homeAway { return isHome ? ha == "home" : ha == "away" }
                let teamId = $0.team?.id
                return isHome ? teamId == matchInfo.homeId : teamId == matchInfo.awayId
            }
            guard let roster = entry?.roster, !roster.isEmpty else { return nil }
            let players: [LineupPlayer] = roster.compactMap { e in
                guard let athlete = e.athlete, let id = athlete.id,
                      let name = athlete.displayName else { return nil }
                let raw = (athlete.headshot?.href).flatMap(URL.init(string:))
                return LineupPlayer(
                    id: id, name: name, jersey: e.jersey,
                    position: e.position?.abbreviation,
                    headshot: resizedHeadshot(raw, side: 220),
                    isStarter: e.starter ?? false
                )
            }
            guard !players.isEmpty else { return nil }
            return TeamLineup(formation: entry?.formation,
                              starters: players.filter { $0.isStarter },
                              substitutes: players.filter { !$0.isStarter })
        }

        let homeLineup = team(isHome: true)
        let awayLineup = team(isHome: false)
        guard homeLineup != nil || awayLineup != nil else { return nil }
        return MatchDetails(lineups: Lineups(home: homeLineup, away: awayLineup))
    }

    // MARK: - Equipos de una competición

    /// Un equipo tal cual lo publica ESPN, con su color de marca — para el
    /// riel "Equipos" y la ficha del equipo.
    struct TeamInfo: Sendable, Hashable, Identifiable {
        let id: String
        let name: String
        let abbreviation: String?
        let logo: URL?
        let colorHex: String?
    }

    private struct TeamsFeed: Decodable {
        let sports: [Sport]
        struct Sport: Decodable { let leagues: [League] }
        struct League: Decodable { let teams: [Entry] }
        struct Entry: Decodable { let team: Team }
        struct Team: Decodable {
            let id: String
            let displayName: String?
            let abbreviation: String?
            let color: String?
            let alternateColor: String?
            let logos: [Logo]?
        }
        struct Logo: Decodable { let href: String? }
    }

    /// Todos los equipos que participan en una competición, con su color de
    /// marca — una sola petición para todo el plantel (a diferencia de pedir
    /// el perfil equipo por equipo).
    static func teams(league: String, limit: Int = 50) async -> [TeamInfo] {
        guard let url = URL(string:
            "https://site.api.espn.com/apis/site/v2/sports/soccer/\(league)/teams?limit=\(limit)") else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let feed = try? JSONDecoder().decode(TeamsFeed.self, from: data) else { return [] }
        let entries = feed.sports.first?.leagues.first?.teams ?? []
        return entries.map { entry in
            let t = entry.team
            return TeamInfo(id: t.id,
                            name: t.displayName ?? "Equipo",
                            abbreviation: t.abbreviation,
                            logo: (t.logos?.first?.href).flatMap(URL.init(string:)),
                            colorHex: pickReadableHex(t.color, t.alternateColor))
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: - Grandes equipos (riel de Inicio)

    /// Un grande europeo del riel "Equipos" de Inicio, con la competición
    /// doméstica bajo la que lo buscamos para pedir su `TeamInfo` real.
    private struct BigClubRef { let id: String; let league: String }

    private static let bigClubs: [BigClubRef] = [
        .init(id: "83", league: "esp.1"),    // Barcelona
        .init(id: "86", league: "esp.1"),    // Real Madrid
        .init(id: "132", league: "ger.1"),   // Bayern Múnich
        .init(id: "382", league: "eng.1"),   // Manchester City
        .init(id: "359", league: "eng.1"),   // Arsenal
        .init(id: "1068", league: "esp.1"),  // Atlético de Madrid
        .init(id: "160", league: "fra.1"),   // PSG
        .init(id: "364", league: "eng.1"),   // Liverpool
        .init(id: "363", league: "eng.1"),   // Chelsea
    ]

    /// Un equipo del riel "Equipos" de Inicio, ya con la Champions League como
    /// competición de entrada — de ahí `TeamDetailView` descubre la liga
    /// doméstica real del equipo (vía su perfil) y junta ambos calendarios.
    struct FeaturedTeam: Sendable, Identifiable {
        let team: TeamInfo
        let competition: Competition
        var id: String { team.id }
    }

    /// Los grandes equipos del riel de Inicio, en el orden fijo del diseño —
    /// una sola petición por liga (varios comparten esp.1/eng.1), no una por
    /// equipo.
    static func bigClubTeams() async -> [FeaturedTeam] {
        guard let champions = Competition.featured.first(where: { $0.id == "uefa.champions" }) else { return [] }
        let leagues = Set(bigClubs.map(\.league))
        let byLeague = await withTaskGroup(of: (String, [TeamInfo]).self) { group in
            for league in leagues {
                group.addTask { (league, await teams(league: league)) }
            }
            var result: [String: [TeamInfo]] = [:]
            for await (league, list) in group { result[league] = list }
            return result
        }
        return bigClubs.compactMap { ref in
            guard let info = byLeague[ref.league]?.first(where: { $0.id == ref.id }) else { return nil }
            return FeaturedTeam(team: info, competition: champions)
        }
    }

    /// Selecciones del riel "Equipos" de Inicio (las primeras del ranking FIFA
    /// grabado en la app + Cuba), con el escudo y el id reales de ESPN. Se
    /// abren bajo "Amistosos": de ahí `TeamDetailView` descubre su Nations
    /// League (vía el perfil) y junta ambos calendarios.
    static func countryTeams() async -> [FeaturedTeam] {
        let all = await teams(league: "fifa.friendly", limit: 300)
        let byCode = Dictionary(all.compactMap { team in team.abbreviation.map { ($0.uppercased(), team) } },
                                uniquingKeysWith: { first, _ in first })
        return FIFARanking.featured.compactMap { entry in
            guard let team = byCode[entry.code] else { return nil }
            let info = TeamInfo(id: team.id, name: entry.name, abbreviation: entry.code,
                                logo: team.logo, colorHex: team.colorHex)
            return FeaturedTeam(team: info, competition: .internationalFriendlies)
        }
    }

    // MARK: - Perfil de un equipo (para saber su liga doméstica)

    struct TeamProfile: Sendable, Hashable {
        let colorHex: String?
        /// Slug ESPN de la liga doméstica del equipo (p. ej. "esp.1") — así
        /// sabemos en qué otra competición buscar su posición y calendario.
        let domesticLeagueSlug: String?
        let domesticLeagueName: String?
    }

    private struct TeamProfileFeed: Decodable {
        let team: Team
        struct Team: Decodable {
            let color: String?
            let alternateColor: String?
            let defaultLeague: League?
        }
        struct League: Decodable { let slug: String?; let name: String? }
    }

    static func teamProfile(league: String, teamId: String) async -> TeamProfile? {
        guard let url = URL(string:
            "https://site.api.espn.com/apis/site/v2/sports/soccer/\(league)/teams/\(teamId)") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let feed = try? JSONDecoder().decode(TeamProfileFeed.self, from: data) else { return nil }
        let t = feed.team
        return TeamProfile(colorHex: pickReadableHex(t.color, t.alternateColor),
                           domesticLeagueSlug: t.defaultLeague?.slug,
                           domesticLeagueName: t.defaultLeague?.name)
    }

    // MARK: - Calendario de un equipo

    /// Partidos de un equipo dentro de una competición concreta (liga
    /// doméstica o continental) — para la ficha del equipo y, a falta de
    /// calendario plano, para deducir jornadas reales (ver más abajo).
    ///
    /// ESPN separa resultados (por defecto) de partidos por jugar
    /// (`?fixture=true`) en este mismo endpoint: sin pedir ambos, solo
    /// vuelven partidos ya disputados y nunca los próximos.
    static func teamSchedule(league: String, teamId: String, leagueName: String) async -> [MatchInfo] {
        async let played = fetchTeamSchedule(league: league, teamId: teamId, leagueName: leagueName, fixture: false)
        async let upcoming = fetchTeamSchedule(league: league, teamId: teamId, leagueName: leagueName, fixture: true)
        var seen = Set<String>()
        return (await played + (await upcoming)).filter { seen.insert($0.id).inserted }
    }

    private static func fetchTeamSchedule(league: String, teamId: String, leagueName: String,
                                           fixture: Bool) async -> [MatchInfo] {
        var urlString = "https://site.api.espn.com/apis/site/v2/sports/soccer/\(league)/teams/\(teamId)/schedule"
        if fixture { urlString += "?fixture=true" }
        guard let url = URL(string: urlString) else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let feed = try? JSONDecoder().decode(Feed.self, from: data) else { return [] }
        return matchInfos(from: feed, leagueName: leagueName)
    }

    /// Competiciones de eliminación (Champions, Europa, copas…) no publican
    /// un calendario plano de fechas como las ligas domésticas —
    /// `calendarDates` devuelve vacío—, así que lo deducimos a partir del
    /// calendario real de varios equipos participantes.
    static func calendarDatesFromTeams(league: String, teamIds: [String]) async -> [Date] {
        let sample = Array(teamIds.prefix(10))
        guard !sample.isEmpty else { return [] }
        return await withTaskGroup(of: [Date].self) { group in
            for id in sample {
                group.addTask { await teamSchedule(league: league, teamId: id, leagueName: "").compactMap(\.date) }
            }
            var all: [Date] = []
            for await dates in group { all.append(contentsOf: dates) }
            return all
        }
    }

    // MARK: - Extras

    /// ESPN sirve las fotos de jugador a tamaño completo (~300 KB cada una,
    /// venga un solo recorte para el hero o los 22 de una alineación). Su
    /// proxy "combiner" las redimensiona en su propio CDN — el mismo truco
    /// que usa espn.com — así que pedimos justo el tamaño que vamos a pintar
    /// y bajamos ~15× menos datos. Si no es una URL de espncdn.com (o no se
    /// puede recomponer), se devuelve tal cual.
    static func resizedHeadshot(_ url: URL?, side: Int) -> URL? {
        guard let url, let host = url.host, host.contains("espncdn.com") else { return url }
        var comps = URLComponents()
        comps.scheme = url.scheme
        comps.host = host
        comps.path = "/combiner/i"
        comps.queryItems = [
            URLQueryItem(name: "img", value: url.path),
            URLQueryItem(name: "w", value: String(side)),
            URLQueryItem(name: "h", value: String(side)),
        ]
        return comps.url ?? url
    }

    /// Recorte HD de un jugador representativo del equipo (roster de ESPN).
    private static func headshot(league: String, teamId: String) async -> URL? {
        guard let url = URL(string:
            "https://site.api.espn.com/apis/site/v2/sports/soccer/\(league)/teams/\(teamId)/roster") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return resizedHeadshot(firstHeadshot(from: data), side: 900)
    }

    /// Camina el JSON del roster (plano o agrupado) y devuelve el primer headshot real.
    private static func firstHeadshot(from data: Data) -> URL? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let athletes = obj["athletes"] as? [[String: Any]] else { return nil }
        var constructed: URL?
        for entry in athletes {
            let list = (entry["items"] as? [[String: Any]]) ?? [entry]
            for athlete in list {
                if let hs = athlete["headshot"] as? [String: Any],
                   let href = hs["href"] as? String, let u = URL(string: href) {
                    return u
                }
                if constructed == nil, let id = athlete["id"] as? String {
                    constructed = URL(string: "https://a.espncdn.com/i/headshots/soccer/players/full/\(id).png")
                }
            }
        }
        return constructed
    }

    /// Color del equipo apto como fondo. ESPN a veces da blanco/negro como
    /// principal (Real Madrid "ffffff"): en ese caso usamos el alternativo.
    private static func teamHex(_ team: Feed.Team?) -> String? {
        pickReadableHex(team?.color, team?.alternateColor)
    }

    /// El calendario por equipo (`teams/{id}/schedule`) no manda el escudo en
    /// el JSON —a diferencia del "scoreboard"—, así que lo reconstruimos con
    /// el mismo patrón de URL que usa ESPN para todos los equipos.
    private static func teamLogo(_ team: Feed.Team?) -> URL? {
        if let logo = team?.logo, let url = URL(string: logo) { return url }
        guard let id = team?.id else { return nil }
        return URL(string: "https://a.espncdn.com/i/teamlogos/soccer/500/\(id).png")
    }

    private static func pickReadableHex(_ primary: String?, _ alternate: String?) -> String? {
        func luma(_ hex: String?) -> Double? {
            guard let hex, hex.count == 6, let v = UInt(hex, radix: 16) else { return nil }
            let r = Double((v >> 16) & 0xFF), g = Double((v >> 8) & 0xFF), b = Double(v & 0xFF)
            return (0.299 * r + 0.587 * g + 0.114 * b) / 255
        }
        for hex in [primary, alternate] {
            if let l = luma(hex), l > 0.07, l < 0.85 { return hex }
        }
        return luma(primary) != nil ? primary : nil
    }

    /// "Estadio Coliseum · Getafe" — nombre del estadio y ciudad, cuando ESPN
    /// lo tiene.
    private static func venueLabel(_ venue: Feed.Competition.Venue?) -> String? {
        guard let name = venue?.fullName, !name.isEmpty else { return nil }
        guard let city = venue?.address?.city, !city.isEmpty else { return name }
        return "\(name) · \(city)"
    }

    private static let isoFormatter = ISO8601DateFormatter()

    /// Formatea la fecha del evento en español ("13 sep", "vie 7:30 p. m.").
    private static func text(_ iso: String?, format: String) -> String? {
        guard let iso, let date = parseCalendarDate(iso) else { return nil }
        let df = DateFormatter()
        df.locale = Locale(identifier: "es")
        df.dateFormat = format
        return df.string(from: date)
    }

    private static func friendlyDate(_ iso: String?) -> String? {
        text(iso, format: "d MMM · h:mm a") ?? iso
    }
}

/// Marcadores por liga cacheados 5 minutos: la cartelera pregunta por varios
/// partidos de la misma liga y no tiene sentido repetir la petición.
private actor ScoreboardCache {
    static let shared = ScoreboardCache()
    private var store: [String: (date: Date, matches: [ESPNService.MatchInfo])] = [:]
    private var inFlight: [String: Task<[ESPNService.MatchInfo], Never>] = [:]

    func matches(_ slug: String,
                 loader: @escaping @Sendable () async -> [ESPNService.MatchInfo]) async -> [ESPNService.MatchInfo] {
        if let hit = store[slug], Date().timeIntervalSince(hit.date) < 300 { return hit.matches }
        // Peticiones simultáneas a la misma liga comparten una sola llamada.
        if let running = inFlight[slug] { return await running.value }
        let task = Task { await loader() }
        inFlight[slug] = task
        let fresh = await task.value
        inFlight[slug] = nil
        // Una lista vacía suele ser un fallo de red: no se cachea 5 minutos.
        if !fresh.isEmpty { store[slug] = (Date(), fresh) }
        return fresh
    }
}

/// Alineaciones cacheadas 2 minutos por partido: se piden justo antes del
/// inicio, cuando ESPN pasa de "probable" a confirmada, así que el caché es
/// corto a propósito.
private actor MatchDetailsCache {
    static let shared = MatchDetailsCache()
    private var store: [String: (date: Date, details: ESPNService.MatchDetails?)] = [:]

    func details(_ eventId: String,
                 loader: @Sendable () async -> ESPNService.MatchDetails?) async -> ESPNService.MatchDetails? {
        if let hit = store[eventId], Date().timeIntervalSince(hit.date) < 120 { return hit.details }
        let fresh = await loader()
        store[eventId] = (Date(), fresh)
        return fresh
    }
}
