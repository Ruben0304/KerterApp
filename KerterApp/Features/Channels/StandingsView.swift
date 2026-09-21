import SwiftUI

/// Pantalla de una competición: Partidos, Tabla de posiciones y Calendario en
/// pestañas — cabecera con el logo y, en Tabla, la clasificación con zonas de
/// color (Champions, descenso…) como en Apple Sports.
struct StandingsView: View {
    let competition: Competition
    /// Partidos de la cartelera de esta competición (pestaña "Partidos").
    let items: [EventItem]
    /// Partido tocado desde Partidos o el calendario: abre la misma ficha.
    let onSelectMatch: (EventItem) -> Void

    private enum Tab: String, CaseIterable { case matches = "Partidos", table = "Tabla", schedule = "Calendario" }

    @State private var standings: LeagueStandings?
    @State private var failed = false
    @State private var tab: Tab = .matches
    @State private var teams: [ESPNService.TeamInfo] = []

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    private var topPad: CGFloat { compact ? 8 : 20 }
    #else
    private let compact = false
    private let topPad: CGFloat = 52
    #endif

    private var cardWidth: CGFloat? { compact ? nil : 340 }
    private var matchColumns: [GridItem] {
        if compact {
            return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        }
        return [GridItem(.adaptive(minimum: 340, maximum: 380), spacing: 24)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch tab {
                case .matches: matchesContent
                case .table: tableContent
                case .schedule: CompetitionScheduleView(competition: competition, onSelect: onSelectMatch)
                }

                if !teams.isEmpty { teamsRow }
            }
            .padding(.horizontal, compact ? 16 : 32)
            .padding(.top, topPad)
            .padding(.bottom, 40)
        }
        .task(id: competition.id) { await load() }
        .task(id: competition.id) { teams = await ESPNService.teams(league: competition.id) }
        .navigationDestination(for: TeamNavTarget.self) { target in
            TeamDetailView(team: target.team, competition: target.competition,
                           combineCompetitions: target.combineCompetitions, onSelectMatch: onSelectMatch)
        }
    }

    // MARK: - Equipos

    /// Mismo carrusel que "Competiciones" en Inicio, pero de los equipos que
    /// participan en esta competición — con el color de cada uno al pasar el
    /// ratón, como los mosaicos de competición.
    private var teamsRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Equipos").font(.title3.weight(.bold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 18) {
                    ForEach(teams) { team in
                        NavigationLink(value: TeamNavTarget(team: team, competition: competition)) {
                            TeamTile(team: team)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 2)
            }
        }
    }

    @ViewBuilder
    private var matchesContent: some View {
        if items.isEmpty {
            ContentUnavailableView("No hay partidos de \(competition.name) hoy", systemImage: "sportscourt",
                                   description: Text("Cuando la cartelera tenga partidos aparecerán aquí."))
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else {
            LazyVGrid(columns: matchColumns, alignment: .leading, spacing: compact ? 16 : 24) {
                ForEach(items) { item in
                    EventCard(channel: item.card, action: { onSelectMatch(item) }, width: cardWidth)
                }
            }
        }
    }

    @ViewBuilder
    private var tableContent: some View {
        if let standings {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(standings.groups) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        if standings.groups.count > 1 || group.name != competition.name {
                            Text(group.name)
                                .font(.title3.weight(.bold))
                        }
                        StandingsTable(rows: group.rows)
                    }
                }
                if !standings.zones.isEmpty { legend(standings.zones) }
            }
        } else if failed {
            ContentUnavailableView {
                Label("No se pudo cargar la tabla", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Revisa tu conexión e inténtalo de nuevo.")
            } actions: {
                Button("Reintentar") { Task { await load() } }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        } else {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
        }
    }

    private func load() async {
        failed = false
        standings = nil
        let result = await StandingsService.standings(league: competition.id)
        standings = result
        failed = result == nil
    }

    // MARK: - Cabecera

    private var header: some View {
        HStack(spacing: 22) {
            CachedImage(url: competition.logoURL, contentMode: .fit,
                        placeholder: .clear)
                .frame(width: 84, height: 84)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(competition.name)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .background {
            ZStack {
                Color(hex: 0x15181F)
                LinearGradient(colors: [Color(hex: competition.brandHex).opacity(0.75),
                                        Color(hex: competition.brandHex).opacity(0.15)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    private var subtitle: String {
        switch tab {
        case .matches: return items.count == 1 ? "1 partido" : "\(items.count) partidos"
        case .table: return standings?.season.map { "Tabla de posiciones · \($0)" } ?? "Tabla de posiciones"
        case .schedule: return "Calendario"
        }
    }

    private func legend(_ zones: [(name: String, color: String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(zones, id: \.name) { zone in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hexString: zone.color) ?? .gray)
                        .frame(width: 12, height: 12)
                    Text(zone.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Tabla

struct StandingsTable: View {
    let rows: [StandingRow]

    #if os(macOS)
    private let showsRecord = true
    #else
    private let showsRecord = false
    #endif
    private let statWidth: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            Divider()
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                StandingsRowView(row: row, statWidth: statWidth, showsRecord: showsRecord,
                                 striped: index.isMultiple(of: 2))
                if index < rows.count - 1 {
                    Divider().opacity(0.4)
                }
            }
        }
        .background(Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("#").frame(width: 48)
            Text("Equipo").frame(maxWidth: .infinity, alignment: .leading)
            column("PJ")
            if showsRecord {
                column("G")
                column("E")
                column("P")
            }
            column("DG")
            Text("Pts")
                .frame(width: statWidth + 14)
                .padding(.trailing, 10)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(height: 36)
    }

    private func column(_ title: String) -> some View {
        Text(title).frame(width: statWidth)
    }
}

struct StandingsRowView: View {
    let row: StandingRow
    let statWidth: CGFloat
    let showsRecord: Bool
    let striped: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            // Barra de zona (Champions, Europa League, descenso…).
            Rectangle()
                .fill(Color(hexString: row.zoneColor) ?? .clear)
                .frame(width: 4)
            Text("\(row.rank)")
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .frame(width: 44)

            HStack(spacing: 12) {
                CachedImage(url: row.logo, contentMode: .fit, placeholder: .clear)
                    .frame(width: 26, height: 26)
                Text(row.team)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            stat(row.played)
            if showsRecord {
                stat(row.wins)
                stat(row.ties)
                stat(row.losses)
            }
            stat(row.goalDifference)
                .foregroundStyle(row.goalDifference.hasPrefix("-") ? .red.opacity(0.85)
                                 : (row.goalDifference.hasPrefix("+") ? Theme.accent : .secondary))
            Text(row.points)
                .font(.body.weight(.bold))
                .monospacedDigit()
                .frame(width: statWidth + 14)
                .padding(.trailing, 10)
        }
        .frame(height: 50)
        .background(hovering ? Color.primary.opacity(0.07)
                             : (striped ? Color.primary.opacity(0.02) : .clear))
        .help(row.zone ?? "")
        .onHover { hovering = $0 }
    }

    private func stat(_ value: String) -> some View {
        Text(value)
            .font(.body)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: statWidth)
    }
}

// MARK: - Mosaico de equipo

/// A qué competición pertenece el equipo tocado — para buscar su posición y
/// calendario también ahí, además de en la competición doméstica que se
/// descubre al abrir la ficha.
struct TeamNavTarget: Hashable {
    let team: ESPNService.TeamInfo
    let competition: Competition
    /// `true` solo desde el riel "Equipos" de Inicio: junta el calendario de
    /// esta competición con el de la liga doméstica del equipo.
    var combineCompetitions: Bool = false
}

struct TeamTile: View {
    let team: ESPNService.TeamInfo
    @State private var hovering = false

    private let size: CGFloat = 100
    private var brand: Color { team.colorHex.flatMap { Color(hexString: $0) } ?? Theme.accent }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Color(hex: 0x15181F))
                Circle().fill(RadialGradient(colors: [brand.opacity(hovering ? 0.55 : 0), .clear],
                                             center: .center, startRadius: 0, endRadius: size * 0.62))
                CachedImage(url: team.logo, contentMode: .fit, placeholder: .clear)
                    .frame(width: size * 0.66, height: size * 0.66)
            }
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(hovering ? brand : Color.white.opacity(0.08),
                                           lineWidth: hovering ? 2 : 1))
            .shadow(color: hovering ? brand.opacity(0.6) : .black.opacity(0.5),
                    radius: hovering ? 18 : 10, y: hovering ? 4 : 6)
            .scaleEffect(hovering ? 1.05 : 1)

            Text(team.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: size)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
    }
}
