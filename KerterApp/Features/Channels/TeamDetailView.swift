import SwiftUI

/// Ficha de un equipo: su posición en la competición actual y en su liga
/// doméstica (al estilo FIFA/EA FC), y su calendario de partidos — con las
/// mismas tarjetas que en Inicio. Al entrar desde dentro de una competición
/// (`combineCompetitions == false`) el calendario se queda solo con esa; al
/// entrar desde el riel "Equipos" de Inicio (`true`) se junta con el de la
/// liga doméstica del equipo.
struct TeamDetailView: View {
    let team: ESPNService.TeamInfo
    let competition: Competition
    var combineCompetitions: Bool = false
    let onSelectMatch: (EventItem) -> Void

    @State private var profile: ESPNService.TeamProfile?
    @State private var currentRow: StandingRow?
    @State private var domesticRow: StandingRow?
    @State private var domesticLeagueName: String?
    @State private var domesticLeagueLogo: URL?
    @State private var matches: [ESPNService.MatchInfo] = []
    @State private var loaded = false
    @State private var showsPreviousMatches = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    private var topPad: CGFloat { compact ? 8 : 20 }
    #else
    private let compact = false
    private let topPad: CGFloat = 52
    #endif

    private var brand: Color {
        (team.colorHex ?? profile?.colorHex).flatMap { Color(hexString: $0) } ?? Theme.accent
    }

    private var cardColumns: [GridItem] {
        if compact {
            return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        }
        return [GridItem(.adaptive(minimum: 210, maximum: 260), spacing: 18)]
    }

    /// Un partido finalizado —o cuya hora ya pasó— vive en el historial. Así
    /// la ficha abre centrada en lo siguiente que va a jugar el equipo.
    private func isPrevious(_ match: ESPNService.MatchInfo) -> Bool {
        match.isFinal || (match.date.map { $0 < Date() } ?? false)
    }

    private var upcomingMatches: [ESPNService.MatchInfo] {
        matches.filter { !isPrevious($0) }
            .sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
    }

    private var previousMatches: [ESPNService.MatchInfo] {
        matches.filter(isPrevious)
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    private var visibleMatches: [ESPNService.MatchInfo] {
        upcomingMatches + (showsPreviousMatches ? previousMatches : [])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                positionsRow
                matchesSection
            }
            .padding(.horizontal, compact ? 16 : 32)
            .padding(.top, topPad)
            .padding(.bottom, 40)
        }
        .task(id: team.id) { await load() }
        .navigationTitle(team.name)
    }

    private func load() async {
        async let profileTask = ESPNService.teamProfile(league: competition.id, teamId: team.id)
        async let compStandingsTask = StandingsService.standings(league: competition.id)
        async let compScheduleTask = ESPNService.teamSchedule(league: competition.id, teamId: team.id,
                                                               leagueName: competition.name)
        let (fetchedProfile, compStandings, compMatches) = await (profileTask, compStandingsTask, compScheduleTask)

        profile = fetchedProfile
        currentRow = compStandings?.groups.flatMap(\.rows).first { $0.id == team.id }

        var allMatches = compMatches
        if let slug = fetchedProfile?.domesticLeagueSlug, slug != competition.id {
            let domestic = Competition.featured.first { $0.id == slug }
            let leagueName = domestic?.name ?? fetchedProfile?.domesticLeagueName ?? "Liga"
            domesticLeagueName = leagueName
            domesticLeagueLogo = domestic?.logoURL

            async let domesticStandingsTask = StandingsService.standings(league: slug)
            let domesticStandings: LeagueStandings?
            if combineCompetitions {
                async let domesticScheduleTask = ESPNService.teamSchedule(league: slug, teamId: team.id,
                                                                           leagueName: leagueName)
                let (standings, domesticMatches) = await (domesticStandingsTask, domesticScheduleTask)
                domesticStandings = standings
                allMatches += domesticMatches
            } else {
                domesticStandings = await domesticStandingsTask
            }
            domesticRow = domesticStandings?.groups.flatMap(\.rows).first { $0.id == team.id }
        }
        // Fuera del riel de Inicio, el calendario se queda solo con la
        // competición seleccionada: no la combinamos con la liga doméstica.
        matches = allMatches.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        loaded = true
    }

    // MARK: - Cabecera

    private var header: some View {
        HStack(spacing: 22) {
            CachedImage(url: team.logo, contentMode: .fit, placeholder: .clear)
                .frame(width: 84, height: 84)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(team.name)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.white)
                Text(domesticLeagueName ?? competition.name)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .background {
            ZStack {
                Color(hex: 0x15181F)
                LinearGradient(colors: [brand.opacity(0.75), brand.opacity(0.15)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Posiciones (estilo FIFA)

    @ViewBuilder
    private var positionsRow: some View {
        if currentRow != nil || domesticRow != nil {
            HStack(alignment: .top, spacing: 16) {
                if let row = currentRow {
                    positionCard(leagueName: competition.name, logo: competition.logoURL,
                                brand: Color(hex: competition.brandHex), row: row)
                }
                if let row = domesticRow, let name = domesticLeagueName {
                    positionCard(leagueName: name, logo: domesticLeagueLogo, brand: brand, row: row)
                }
            }
        }
    }

    private func positionCard(leagueName: String, logo: URL?, brand: Color, row: StandingRow) -> some View {
        HStack(spacing: 14) {
            CachedImage(url: logo, contentMode: .fit, placeholder: .clear)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(leagueName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(row.rank)º lugar")
                    .font(.title3.weight(.bold))
                Text("\(row.points) pts · \(row.played) PJ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(brand.opacity(0.4), lineWidth: 1))
    }

    // MARK: - Calendario del equipo

    @ViewBuilder
    private var matchesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Próximos partidos").font(.title3.weight(.bold))
                Spacer()
                if !previousMatches.isEmpty {
                    Button(showsPreviousMatches ? "Ocultar anteriores" : "Ver anteriores") {
                        withAnimation(.snappy) { showsPreviousMatches.toggle() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                }
            }

            if !loaded {
                ProgressView().controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else if matches.isEmpty {
                ContentUnavailableView("Sin partidos", systemImage: "sportscourt",
                                       description: Text("No encontramos el calendario de \(team.name)."))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else if visibleMatches.isEmpty {
                ContentUnavailableView("No hay próximos partidos", systemImage: "calendar",
                                       description: Text("Puedes consultar los encuentros anteriores del equipo."))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else {
                LazyVGrid(columns: cardColumns, alignment: .leading, spacing: compact ? 16 : 18) {
                    ForEach(visibleMatches, id: \.id) { match in
                        Button {
                            onSelectMatch(EventItem.highlightsOnly(match, league: match.league))
                        } label: {
                            TeamMatchCard(match: match, teamId: team.id)
                        }
                        .buttonStyle(.plain)
                        // Los próximos encuentros no tienen resumen todavía,
                        // pero conservan el mismo acabado visual que el resto.
                        .allowsHitTesting(match.isFinal)
                    }
                }
            }
        }
    }
}

// MARK: - Tarjeta de partido del calendario (rival, día y estadio)

/// Tarjeta minimal para el calendario de un equipo: solo el escudo del
/// rival, el día y el estadio — sin marcador ni píldoras, para que el
/// calendario completo (partidos jugados y por jugar) se lea de un vistazo.
private struct TeamMatchCard: View {
    let match: ESPNService.MatchInfo
    let teamId: String

    @State private var hovering = false

    private var isHome: Bool { match.homeId == teamId }
    private var opponentName: String { isHome ? match.away : match.home }
    private var opponentLogo: URL? { isHome ? match.awayLogo : match.homeLogo }
    private var opponentColor: String? { isHome ? match.awayColor : match.homeColor }

    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "es")
        df.dateFormat = "EEE d MMM · HH:mm"
        df.timeZone = TimeZone(identifier: "UTC")
        return df
    }()

    private var dayText: String {
        guard let date = match.date else { return match.dateLabel ?? match.schedule ?? "" }
        return Self.dayFormatter.string(from: date).capitalized
    }

    private var brand: Color {
        opponentColor.flatMap { Color(hexString: $0) } ?? Theme.accent
    }

    var body: some View {
        VStack(spacing: 16) {
            Group {
                if let opponentLogo {
                    CachedImage(url: opponentLogo, contentMode: .fit, placeholder: .clear)
                } else {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(brand.opacity(0.7))
                }
            }
            .frame(width: 60, height: 60)
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)

            VStack(spacing: 4) {
                Text(opponentName)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(dayText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let venue = match.venue, !venue.isEmpty {
                    Text(venue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(RadialGradient(colors: [brand.opacity(hovering ? 0.25 : 0.1), .clear],
                                         center: .top, startRadius: 0, endRadius: 150))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(hovering ? brand.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 1))
        .scaleEffect(hovering ? 1.02 : 1)
        .shadow(color: hovering ? brand.opacity(0.25) : .clear, radius: 14, y: 6)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        .onHover { hovering = $0 }
    }
}
