import Foundation

/// Fila cruda de `/api/assignments`: una asignación evento → canal.
struct Assignment: Decodable {
    let eventApiId: String?
    let eventTitle: String?
    let eventLeague: String?
    let eventSport: String?
    let eventTime: String?
    let eventDate: String?
    let channelId: Int?
    let channelName: String?
    let channelLogo: String?
    let homeLogo: String?
    let awayLogo: String?
    let hidden: Bool?
}

/// Un canal que transmite un evento.
struct EventChannel: Identifiable, Hashable {
    let id: Int
    let name: String
    let logo: URL?

    private var nameKey: String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    /// "Kerter+ 1", "Kerter+ 3", "Kerter Plus 4K"…: los propios, que suelen
    /// ir mejor que los de terceros.
    var isKerterPlus: Bool { nameKey.contains("kerter") }

    /// Calidad que anuncia el nombre: 4K/UHD > FHD/1080 > HD > sin indicar.
    var qualityRank: Int {
        let key = nameKey
        if key.contains("4k") || key.contains("uhd") || key.contains("2160") { return 3 }
        if key.contains("fhd") || key.contains("1080") { return 2 }
        if key.contains("hd") || key.contains("720") { return 1 }
        return 0
    }
}

/// Un partido/evento con el grupo de canales que lo transmiten (como en la web).
struct LiveEvent: Identifiable, Hashable {
    let id: String
    let home: String
    let away: String
    let league: String?
    let sport: String?
    let time: String?
    let homeLogo: URL?
    let awayLogo: URL?
    var channels: [EventChannel]

    /// Canal para la vista previa (y el elegido de entrada en la ficha): un
    /// Kerter+ reproducible, el que sea y aunque no vaya primero, y de ellos el
    /// de mejor calidad; si no hay, cualquier otro reproducible; y si ninguno
    /// lo es, el Kerter+ o el primero.
    func previewOption(resolve: (EventChannel) -> Channel?) -> EventChannel? {
        let playable = channels.filter { resolve($0)?.canPreview == true }
        let best = { (options: [EventChannel]) in
            options.enumerated()
                .max { a, b in
                    a.element.qualityRank != b.element.qualityRank
                        ? a.element.qualityRank < b.element.qualityRank
                        : a.offset > b.offset   // empate: el que va antes
                }?.element
        }
        return best(playable.filter(\.isKerterPlus)) ?? best(playable)
            ?? best(channels.filter(\.isKerterPlus)) ?? channels.first
    }

    /// "Elche vs Real Madrid" (local vs visitante).
    var title: String { home.isEmpty ? away : "\(home) vs \(away)" }

    /// Agrupa las asignaciones por evento y junta sus canales.
    static func group(_ assignments: [Assignment]) -> [LiveEvent] {
        var order: [String] = []
        var map: [String: LiveEvent] = [:]

        for a in assignments where a.hidden != true {
            let rawTitle = a.eventTitle ?? "Evento"
            let key = a.eventApiId ?? rawTitle
            // El backend usa el formato "Visitante at Local".
            let parts = rawTitle.components(separatedBy: " at ")
            let away = parts.count == 2 ? parts[0].trimmingCharacters(in: .whitespaces) : rawTitle
            let home = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

            if map[key] == nil {
                order.append(key)
                map[key] = LiveEvent(
                    id: key, home: home, away: away,
                    league: a.eventLeague,
                    sport: SportsFilterSettings.canonicalSport(a.eventSport, league: a.eventLeague),
                    time: a.eventTime,
                    homeLogo: a.homeLogo.flatMap { $0.isEmpty ? nil : URL(string: $0) },
                    awayLogo: a.awayLogo.flatMap { $0.isEmpty ? nil : URL(string: $0) },
                    channels: []
                )
            }
            if let cid = a.channelId, let cname = a.channelName, !cname.isEmpty,
               !(map[key]?.channels.contains(where: { $0.id == cid }) ?? false) {
                map[key]?.channels.append(
                    EventChannel(id: cid, name: cname,
                                 logo: a.channelLogo.flatMap { $0.isEmpty ? nil : URL(string: $0) })
                )
            }
        }
        return order.compactMap { map[$0] }.filter { !$0.channels.isEmpty }
    }
}
