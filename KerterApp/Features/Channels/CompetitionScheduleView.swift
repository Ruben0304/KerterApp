import SwiftUI

/// Calendario de una competición: tira de jornadas y, debajo, los partidos de
/// la fecha elegida — igual que el calendario de las apps de resultados.
struct CompetitionScheduleView: View {
    let competition: Competition
    /// Solo los partidos terminados abren la ficha (en modo resumen); los que
    /// faltan por jugar no tienen nada que mostrar todavía.
    let onSelect: (EventItem) -> Void

    @State private var dates: [Date] = []
    @State private var selected: Date?
    @State private var matches: [ESPNService.MatchInfo] = []
    @State private var loadedDates = false
    @State private var loadingMatches = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    #endif

    private var cardWidth: CGFloat? { compact ? nil : 340 }
    private var matchColumns: [GridItem] {
        if compact {
            return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        }
        return [GridItem(.adaptive(minimum: 340, maximum: 380), spacing: 24)]
    }

    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "es")
        df.dateFormat = "EEE"
        df.timeZone = TimeZone(identifier: "UTC")
        return df
    }()
    private static let numberFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "es")
        df.dateFormat = "d"
        df.timeZone = TimeZone(identifier: "UTC")
        return df
    }()
    private static let monthFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "es")
        df.dateFormat = "MMM"
        df.timeZone = TimeZone(identifier: "UTC")
        return df
    }()

    private var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// Colapsa fechas con hora (varios partidos el mismo día) a un día por
    /// jornada, ordenadas — el calendario deducido de equipos trae horas.
    private func uniqueDays(_ raw: [Date]) -> [Date] {
        var seen = Set<Date>()
        var result: [Date] = []
        for date in raw.sorted() {
            let day = utcCalendar.startOfDay(for: date)
            if seen.insert(day).inserted { result.append(day) }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !loadedDates {
                ProgressView().controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 50)
            } else if dates.isEmpty {
                ContentUnavailableView("Sin calendario", systemImage: "calendar",
                                       description: Text("No encontramos las jornadas de esta competición."))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 50)
            } else {
                dateStrip
                matchList
            }
        }
        .task {
            var found = await ESPNService.calendarDates(league: competition.id)
            if found.isEmpty {
                // Competiciones de eliminación (Champions, Europa…) no
                // publican un calendario plano: lo deducimos del calendario
                // real de varios equipos participantes.
                let teamIds = (await StandingsService.standings(league: competition.id))?
                    .groups.flatMap(\.rows).map(\.id) ?? []
                let raw = await ESPNService.calendarDatesFromTeams(league: competition.id, teamIds: teamIds)
                found = uniqueDays(raw)
            }
            dates = found
            let today = utcCalendar.startOfDay(for: Date())
            selected = dates.first(where: { $0 >= today }) ?? dates.last
            loadedDates = true
        }
        .task(id: selected) {
            guard let selected else { return }
            loadingMatches = true
            matches = await ESPNService.matches(league: competition.id, leagueName: competition.name, on: selected)
            loadingMatches = false
        }
    }

    private var dateStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(dates, id: \.self) { date in
                        dateChip(date).id(date)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
            .onAppear {
                guard let selected else { return }
                DispatchQueue.main.async { proxy.scrollTo(selected, anchor: .center) }
            }
        }
    }

    private func dateChip(_ date: Date) -> some View {
        let isSelected = selected.map { utcCalendar.isDate($0, inSameDayAs: date) } ?? false
        return Button {
            withAnimation(.snappy) { selected = date }
        } label: {
            VStack(spacing: 3) {
                Text(Self.dayFormatter.string(from: date).capitalized)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
                Text(Self.numberFormatter.string(from: date))
                    .font(.headline.weight(.bold))
                Text(Self.monthFormatter.string(from: date).capitalized)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .frame(width: 56, height: 64)
            .background(isSelected ? Color(hex: competition.brandHex) : Color.primary.opacity(0.05),
                       in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Mismas tarjetas de partido que en Inicio ("Partidos" y las de
    /// competición) — solo terminados abren la ficha, en modo resumen.
    @ViewBuilder
    private var matchList: some View {
        if loadingMatches {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
        } else if matches.isEmpty {
            ContentUnavailableView("Sin partidos ese día", systemImage: "sportscourt")
                .frame(maxWidth: .infinity)
                .padding(.top, 30)
        } else {
            LazyVGrid(columns: matchColumns, alignment: .leading, spacing: compact ? 16 : 24) {
                ForEach(matches, id: \.id) { match in
                    let item = EventItem.highlightsOnly(match, league: competition.name)
                    EventCard(channel: item.card, action: { onSelect(item) }, width: cardWidth)
                        // Los próximos partidos aún no tienen resumen, pero no
                        // deben verse atenuados: se muestran como una card
                        // normal y simplemente no reciben interacción.
                        .allowsHitTesting(match.isFinal)
                }
            }
        }
    }
}
