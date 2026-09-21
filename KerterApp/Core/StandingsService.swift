import Foundation

/// Una fila de la tabla de posiciones.
struct StandingRow: Identifiable, Hashable {
    let id: String
    let rank: Int
    let team: String
    let abbreviation: String?
    let logo: URL?
    let played: String
    let wins: String
    let ties: String
    let losses: String
    let goalDifference: String
    let points: String
    /// Zona de la tabla ("Champions League", "Descenso") y su color hex.
    let zone: String?
    let zoneColor: String?
}

struct StandingsGroup: Identifiable, Hashable {
    let name: String
    let rows: [StandingRow]
    var id: String { name }
}

struct LeagueStandings: Hashable {
    let season: String?
    let groups: [StandingsGroup]

    /// Leyenda de zonas en el orden en que aparecen en la tabla.
    var zones: [(name: String, color: String)] {
        var seen = Set<String>()
        var result: [(String, String)] = []
        for row in groups.flatMap(\.rows) {
            guard let zone = row.zone, let color = row.zoneColor, !seen.contains(zone) else { continue }
            seen.insert(zone)
            result.append((zone, color))
        }
        return result
    }
}

/// Tabla de posiciones desde la API pública de ESPN.
enum StandingsService {

    private struct Response: Decodable {
        let children: [Child]?
        struct Child: Decodable {
            let name: String?
            let standings: Standings?
        }
        struct Standings: Decodable {
            let seasonDisplayName: String?
            let entries: [Entry]?
        }
        struct Entry: Decodable {
            let team: Team
            let stats: [Stat]?
            let note: Note?
        }
        struct Team: Decodable {
            let id: String?
            let displayName: String?
            let abbreviation: String?
            let logos: [Logo]?
        }
        struct Logo: Decodable { let href: String? }
        struct Stat: Decodable {
            let name: String?
            let displayValue: String?
        }
        struct Note: Decodable {
            let color: String?
            let description: String?
        }
    }

    static func standings(league: String) async -> LeagueStandings? {
        guard let url = URL(string:
            "https://site.api.espn.com/apis/v2/sports/soccer/\(league)/standings") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }

        let children = response.children ?? []
        let groups: [StandingsGroup] = children.compactMap { child in
            guard let entries = child.standings?.entries, !entries.isEmpty else { return nil }
            let rows = entries.enumerated().map { index, entry -> StandingRow in
                func stat(_ name: String) -> String {
                    entry.stats?.first { $0.name == name }?.displayValue ?? "–"
                }
                return StandingRow(
                    id: entry.team.id ?? "\(index)",
                    rank: Int(stat("rank")) ?? index + 1,
                    team: entry.team.displayName ?? "Equipo",
                    abbreviation: entry.team.abbreviation,
                    logo: entry.team.logos?.first?.href.flatMap(URL.init(string:)),
                    played: stat("gamesPlayed"),
                    wins: stat("wins"),
                    ties: stat("ties"),
                    losses: stat("losses"),
                    goalDifference: stat("pointDifferential"),
                    points: stat("points"),
                    zone: entry.note?.description,
                    zoneColor: entry.note?.color?.replacingOccurrences(of: "#", with: "")
                )
            }
            .sorted { $0.rank < $1.rank }
            return StandingsGroup(name: child.name ?? "Clasificación", rows: rows)
        }
        guard !groups.isEmpty else { return nil }
        return LeagueStandings(season: children.first?.standings?.seasonDisplayName, groups: groups)
    }
}
