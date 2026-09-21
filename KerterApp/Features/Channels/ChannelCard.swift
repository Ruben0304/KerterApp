import SwiftUI

// MARK: - Iconografía de deportes

func sportIcon(for category: String?) -> String {
    switch (category ?? "").lowercased() {
    case let c where c.contains("fútbol") || c.contains("futbol") || c.contains("soccer"): return "soccerball"
    case let c where c.contains("balonc") || c.contains("nba") || c.contains("basket"): return "basketball.fill"
    case let c where c.contains("ufc") || c.contains("mma"): return "figure.martial.arts"
    case let c where c.contains("box"): return "figure.boxing"
    case let c where c.contains("motoc"): return "figure.outdoor.cycle"
    case let c where c.contains("motor") || c.contains("f1"): return "car.side.fill"
    case let c where c.contains("béis") || c.contains("beis") || c.contains("mlb"): return "baseball.fill"
    case let c where c.contains("tenis") || c.contains("tennis"): return "tennis.racket"
    case let c where c.contains("rugby"): return "figure.rugby"
    case let c where c.contains("pádel") || c.contains("padel"): return "figure.tennis"
    case let c where c.contains("hockey"): return "figure.hockey"
    case let c where c.contains("deporte"): return "sportscourt.fill"
    case let c where c.contains("pelícu") || c.contains("pelicu") || c.contains("cine"): return "film.fill"
    case let c where c.contains("noticia"): return "newspaper.fill"
    case let c where c.contains("música") || c.contains("musica"): return "music.note"
    case let c where c.contains("infantil") || c.contains("niño"): return "teddybear.fill"
    case let c where c.contains("novela"): return "heart.fill"
    case let c where c.contains("entreten"): return "sparkles.tv.fill"
    case let c where c.contains("documental"): return "globe.americas.fill"
    case let c where c.contains("cuban"): return "flag.fill"
    case let c where c.contains("kerter"): return "star.fill"
    case let c where c.contains("app"): return "square.grid.2x2.fill"
    default: return "tv.fill"
    }
}

// MARK: - Poster compuesto (fallback cuando no hay imagen del backend)

/// Fondo elegante para eventos sin imagen: gradiente por deporte + icono grande.
struct ComposedPoster: View {
    let channel: Channel
    var body: some View {
        ZStack {
            LinearGradient(colors: gradientColors,
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: sportIcon(for: channel.category))
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(.white.opacity(0.16))
                .offset(x: 60, y: 20)
            VStack {
                Spacer()
                HStack {
                    Text(initials(from: channel.name))
                        .font(.system(size: 30, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.95))
                    Spacer()
                }
            }
            .padding(14)
        }
    }

    private var gradientColors: [Color] {
        switch (channel.category ?? "").lowercased() {
        case let c where c.contains("fútbol") || c.contains("futbol"): return [Color(hex: 0x1B4A3A), Color(hex: 0x0F2A34)]
        case let c where c.contains("tenis"): return [Color(hex: 0x1E3A5F), Color(hex: 0x0C1E33)]
        case let c where c.contains("balonc"): return [Color(hex: 0x5A2E12), Color(hex: 0x2A1408)]
        case let c where c.contains("motor") || c.contains("motoc"): return [Color(hex: 0x4A1420), Color(hex: 0x1E0A10)]
        case let c where c.contains("box") || c.contains("ufc"): return [Color(hex: 0x3A2A12), Color(hex: 0x1A1408)]
        default: return [Color(hex: 0x243244), Color(hex: 0x121722)]
        }
    }
}

/// Imagen del evento. Prioridad:
/// 1) portada/poster si hay  2) escudos + colores de los equipos  3) negro.
struct EventPoster: View {
    let channel: Channel
    var body: some View {
        if channel.posterURL != nil || channel.heroImageURL != nil {
            ZStack {
                Color.black
                CachedImage(url: channel.posterURL ?? channel.heroImageURL,
                            contentMode: .fill, placeholder: .clear)
            }
        } else if channel.homeLogoURL != nil || channel.awayLogoURL != nil {
            TeamVersusPoster(channel: channel)
        } else if channel.logoURL != nil {
            LogoPoster(channel: channel)
        } else {
            Color.black
        }
    }
}

/// Póster para canales de TV: logo centrado sobre un fondo con color de marca.
struct LogoPoster: View {
    let channel: Channel
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x1E2735), Color(hex: 0x0B0F16)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.08), .clear],
                           center: .center, startRadius: 0, endRadius: 140)
            CachedImage(url: channel.logoURL, contentMode: .fit, placeholder: .clear)
                .frame(maxWidth: 150, maxHeight: 96)
                .padding(16)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
        }
    }
}

/// Portada team-vs-team: cada mitad con el color del equipo, fundidas sin corte.
struct TeamVersusPoster: View {
    let channel: Channel

    private func tone(_ hex: String?, _ brightness: Double, fallback: UInt) -> Color {
        Color(hexString: hex, brightness: brightness) ?? Color(hex: fallback)
    }

    var body: some View {
        ZStack {
            LinearGradient(stops: [
                .init(color: tone(channel.homeColor, 0.9, fallback: 0x1B2B4A), location: 0),
                .init(color: tone(channel.homeColor, 0.45, fallback: 0x0E1830), location: 0.42),
                .init(color: tone(channel.awayColor, 0.45, fallback: 0x16091E), location: 0.58),
                .init(color: tone(channel.awayColor, 0.9, fallback: 0x2A1030), location: 1),
            ], startPoint: .topLeading, endPoint: .bottomTrailing)

            // Profundidad: base más oscura para que el badge y el play resalten.
            LinearGradient(colors: [.white.opacity(0.06), .clear, .black.opacity(0.4)],
                           startPoint: .top, endPoint: .bottom)

            HStack {
                logo(channel.homeLogoURL)
                Spacer()
                logo(channel.awayLogoURL)
            }
            .padding(.horizontal, 22)
            Text("VS")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.4), radius: 4)
        }
    }

    private func logo(_ url: URL?) -> some View {
        CachedImage(url: url, contentMode: .fit, placeholder: .clear)
            .frame(width: 62, height: 62)
            .background(
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.22), .clear],
                                         center: .center, startRadius: 0, endRadius: 52))
                    .frame(width: 104, height: 104)
            )
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
    }
}

// MARK: - Tarjeta de competición

struct CompetitionTile: View {
    let competition: Competition
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var size: CGFloat { sizeClass == .compact ? 84 : 124 }
    #else
    private let size: CGFloat = 124
    #endif
    private var brand: Color { Color(hex: competition.brandHex) }
    private var active: Bool { hovering || isSelected }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color(hex: 0x15181F))
                    // Al pasar el ratón se enciende con el color de la competición.
                    Circle().fill(RadialGradient(colors: [brand.opacity(active ? 0.55 : 0), .clear],
                                                 center: .center, startRadius: 0,
                                                 endRadius: size * 0.62))
                    CachedImage(url: competition.logoURL, contentMode: .fit,
                                placeholder: .clear)
                        .frame(width: size * 0.66, height: size * 0.66)
                }
                .frame(width: size, height: size)
                .overlay(
                    Circle().strokeBorder(active ? brand : Color.white.opacity(0.08),
                                          lineWidth: active ? 2 : 1)
                )
                .shadow(color: active ? brand.opacity(0.6) : .black.opacity(0.5),
                        radius: active ? 18 : 10, y: active ? 4 : 6)
                .scaleEffect(hovering ? 1.05 : 1)

                Text(competition.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .frame(width: size)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - Tarjeta de evento (riel horizontal)

struct EventCard: View {
    let channel: Channel
    let action: () -> Void
    /// `nil` deja que una cuadrícula vertical adapte la card al ancho de su
    /// celda; los rieles horizontales siguen fijándola a 340 pt.
    var width: CGFloat? = 340

    @State private var hovering = false

    /// Partido con escudos → tarjeta tipo Apple TV (todo dentro de la tarjeta).
    private var isMatch: Bool {
        channel.homeLogoURL != nil && channel.awayLogoURL != nil
    }

    var body: some View {
        Button(action: action) {
            if isMatch && !isPlayed {
                MatchCard(channel: channel, hovering: hovering)
                    .frame(width: width)
            } else if isMatch {
                // Jugado / en vivo: misma proporción y nombre debajo que las
                // tarjetas con portada, para que el riel no tenga alturas distintas.
                VStack(alignment: .leading, spacing: 8) {
                    MatchCard(channel: channel, hovering: hovering, aspect: 16.0 / 9.0)
                    captions
                }
                .frame(width: width, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    poster
                    captions
                }
                .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        .onHover { hovering = $0 }
    }

    private var isPlayed: Bool {
        (channel.isFinal || channel.isLive) && channel.homeScore != nil
    }

    private var captions: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(channel.scheduleLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(channel.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(channel.subtitle ?? channel.category ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var poster: some View {
        EventPoster(channel: channel)
            .aspectRatio(16.0/9.0, contentMode: .fill)
            .frame(width: width)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .topLeading) {
                badge.padding(8)
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                    .padding(8)
                    .opacity(hovering ? 1 : 0.85)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(hovering ? 0.25 : 0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(hovering ? 0.25 : 0),
                    radius: hovering ? 12 : 0, y: hovering ? 6 : 0)
    }

    @ViewBuilder private var badge: some View {
        if channel.isLive {
            LiveBadge(animated: false)
        } else {
            Text("PRÓXIMAMENTE")
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.5)
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color(hex: 0x1EA7C4), in: Capsule())
        }
    }
}

// MARK: - Tarjeta de partido (estilo Apple TV)

/// Réplica de las tarjetas de partido de Apple TV:
/// • Por jugar: fondo partido en diagonal con el color de cada equipo, escudos
///   a cada lado y competición + "Local vs. Visitante" abajo a la izquierda.
///   Sin colores de equipo: fondo oscuro con líneas concéntricas.
/// • Jugado / en vivo: estadio en blanco y negro, escudos con un divisor fino
///   y el marcador abajo con las abreviaturas.
struct MatchCard: View {
    let channel: Channel
    var hovering = false
    var aspect: CGFloat = 3.0 / 2.0

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }
    private var showsScore: Bool {
        (channel.isFinal || channel.isLive) && channel.homeScore != nil
    }
    private var hasTeamColors: Bool { channel.homeColor != nil || channel.awayColor != nil }
    private var title: String { channel.name.replacingOccurrences(of: " vs ", with: " vs. ") }
    private var league: String { (channel.subtitle ?? channel.category ?? "").uppercased() }

    var body: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                if showsScore {
                    stadiumBackground
                } else if hasTeamColors {
                    diagonalBackground
                } else {
                    patternBackground
                }
            }
            .overlay { if showsScore { scoreContent } else { upcomingContent } }
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(hovering ? 0.28 : 0.1), lineWidth: 1))
            .overlay(alignment: .topLeading) { statusPill.padding(12) }
            .overlay(alignment: .topTrailing) { brandMark.padding(.top, 13).padding(.trailing, 14) }
            .shadow(color: .black.opacity(hovering ? 0.35 : 0.15), radius: hovering ? 16 : 6, y: hovering ? 8 : 3)
            .environment(\.colorScheme, .dark)
    }

    // MARK: Fondos

    private var stadiumBackground: some View {
        Color.black.overlay {
            Image("HeroBGDefault")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .grayscale(1)
                .opacity(0.45)
        }
        .clipped()
    }

    private var diagonalBackground: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Color(hexString: channel.homeColor) ?? Color(hex: 0x1C1C1E)
                Path { p in
                    p.move(to: CGPoint(x: w * 0.64, y: 0))
                    p.addLine(to: CGPoint(x: w, y: 0))
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: w * 0.40, y: h))
                    p.closeSubpath()
                }
                .fill(Color(hexString: channel.awayColor) ?? Color(hex: 0x1C1C1E))
                // Brillo suave de tela, como las camisetas en Apple TV.
                LinearGradient(colors: [.white.opacity(0.14), .clear, .black.opacity(0.18)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }

    private var patternBackground: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack {
                LinearGradient(colors: [Color(hex: 0x2C2C30), Color(hex: 0x131315)],
                               startPoint: .top, endPoint: .bottom)
                ForEach(1..<9) { i in
                    RoundedRectangle(cornerRadius: CGFloat(i) * 9, style: .continuous)
                        .stroke(.white.opacity(0.06), lineWidth: 1)
                        .frame(width: h * 0.12 * CGFloat(i), height: h * 0.2 * CGFloat(i))
                }
            }
            .frame(width: geo.size.width, height: h)
            .clipped()
        }
    }

    // MARK: Contenido

    private var upcomingContent: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                LinearGradient(colors: [.clear, .black.opacity(0.4)],
                               startPoint: .init(x: 0.5, y: 0.55), endPoint: .bottom)
                crest(channel.homeLogoURL, size: w * 0.19)
                    .position(x: w * 0.27, y: h * 0.47)
                crest(channel.awayLogoURL, size: w * 0.19)
                    .position(x: w * 0.73, y: h * 0.47)
                VStack(alignment: .leading, spacing: 2) {
                    Text(league)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    Text(title)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .frame(width: w, height: h, alignment: .bottomLeading)
            }
        }
    }

    private var scoreContent: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: w * 0.54, y: h * 0.26))
                    p.addLine(to: CGPoint(x: w * 0.46, y: h * 0.6))
                }
                .stroke(.white.opacity(0.4), lineWidth: 1)

                crest(channel.homeLogoURL, size: w * 0.17)
                    .position(x: w * 0.27, y: h * 0.42)
                crest(channel.awayLogoURL, size: w * 0.17)
                    .position(x: w * 0.73, y: h * 0.42)

                scoreColumn(channel.homeScore, channel.homeAbbr)
                    .position(x: w * 0.27, y: h * 0.8)
                scoreColumn(channel.awayScore, channel.awayAbbr)
                    .position(x: w * 0.73, y: h * 0.8)

                VStack(spacing: 4) {
                    Text(channel.subtitle ?? "")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.black.opacity(0.45), in: Capsule())
                    Text(channel.isLive
                         ? (channel.statusPill ?? "En vivo")
                         : (channel.dateLabel ?? channel.scheduleLabel))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .frame(maxWidth: w * 0.4)
                .position(x: w * 0.5, y: h * 0.76)
            }
        }
    }

    // MARK: Piezas

    private func crest(_ url: URL?, size: CGFloat) -> some View {
        CachedImage(url: url, contentMode: .fit, placeholder: .clear)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }

    private func scoreColumn(_ score: String?, _ abbr: String?) -> some View {
        VStack(spacing: 1) {
            Text(score ?? "–")
                .font(.system(size: 30, weight: .semibold).width(.condensed))
                .foregroundStyle(.white)
                .monospacedDigit()
            Text(abbr ?? "")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    @ViewBuilder private var statusPill: some View {
        if channel.isLive {
            LiveBadge(animated: false)
        } else if let text = channel.statusPill ?? channel.startText, !text.isEmpty {
            let pillShape = RoundedRectangle(cornerRadius: 9, style: .continuous)
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.black.opacity(0.3), in: pillShape)
                .background(.ultraThinMaterial, in: pillShape)
                .overlay(pillShape.strokeBorder(.white.opacity(0.2), lineWidth: 1))
        }
    }

    private var brandMark: some View {
        HStack(spacing: 0) {
            Text("Kerter").fontWeight(.bold)
            Text("+").fontWeight(.heavy).foregroundStyle(Theme.accent)
        }
        .font(.system(size: 16))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.4), radius: 4)
    }
}

// MARK: - Tarjeta de deporte (fila "Explorar por deporte")

struct CategoryCircle: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 18, style: .continuous) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: title == "Todos" ? "square.grid.2x2.fill" : sportIcon(for: title))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle().fill(isSelected ? .white.opacity(0.18) : Theme.accent.opacity(0.14))
                    )
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)
            }
            .padding(.leading, 8).padding(.trailing, 18).padding(.vertical, 8)
            .background(
                shape.fill(isSelected
                           ? AnyShapeStyle(LinearGradient(colors: [Theme.accent, Theme.accentDeep],
                                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                           : AnyShapeStyle(LinearGradient(colors: [Color.primary.opacity(0.10),
                                                                   Color.primary.opacity(0.03)],
                                                          startPoint: .top, endPoint: .bottom)))
            )
            .overlay(
                shape.strokeBorder(LinearGradient(colors: [Color.primary.opacity(hovering ? 0.3 : 0.16),
                                                           Color.primary.opacity(0.03)],
                                                  startPoint: .top, endPoint: .bottom),
                                   lineWidth: 1)
            )
            .shadow(color: isSelected ? Theme.accent.opacity(0.35) : .clear, radius: 10, y: 4)
            .scaleEffect(hovering ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - Barra flotante superior (estilo Disney+)

struct TopNavPill: View {
    @Binding var selection: String
    /// Solo en iOS: si no es `nil`, aparece un 5º item ("Extra") que abre una
    /// pantalla propia (no un menú flotante) con lo que en Mac/iPad vive en
    /// la barra lateral. `nil` en Mac deja la pastilla con sus 4 items de siempre.
    var onExtraTap: (() -> Void)? = nil

    @Namespace private var glass
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    #endif

    private var items: [String] {
        var base = ["Para ti", "Kerter+", "DAZN", "ESPN"]
        // En iPhone la pastilla ya va justa de espacio: quitamos DAZN ahí.
        // En iPad/Mac se queda, hay aire de sobra.
        if compact { base.removeAll { $0 == "DAZN" } }
        if onExtraTap != nil { base.append("Extra") }
        return base
    }

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(items, id: \.self) { item in
                    Group {
                        if item == "Extra" {
                            Button { onExtraTap?() } label: { itemLabel(item, selected: false) }
                        } else {
                            Button {
                                withAnimation(.smooth(duration: 0.3)) { selection = item }
                            } label: {
                                itemLabel(item, selected: selection == item)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .background {
                        // La selección es una gota de cristal blanca que se desliza.
                        if selection == item {
                            Capsule()
                                .fill(.clear)
                                .glassEffect(.regular.tint(.white).interactive(), in: Capsule())
                                .glassEffectID("selection", in: glass)
                        }
                    }
                }
            }
            .padding(5)
            .glassEffect(.regular, in: Capsule())
        }
        .environment(\.colorScheme, .dark)
    }

    private func itemLabel(_ item: String, selected: Bool) -> some View {
        label(for: item, selected: selected)
            .padding(.horizontal, compact ? 11 : 18)
            .padding(.vertical, compact ? 7 : 9)
            .contentShape(Capsule())
    }

    /// Cada marca con su tipografía característica (aprox. al logo real).
    @ViewBuilder
    private func label(for item: String, selected: Bool) -> some View {
        let fg: Color = selected ? .black : .white.opacity(0.92)
        switch item {
        case "Kerter+":
            HStack(spacing: 0) {
                Text("Kerter").fontWeight(.bold)
                Text("+").fontWeight(.black).foregroundStyle(Theme.accent)
            }
            .font(.system(size: 16, design: .rounded))
            .foregroundStyle(fg)
        case "DAZN":
            Text("DAZN")
                .font(.system(size: 15, weight: .black))
                .tracking(1.5)
                .foregroundStyle(fg)
        case "ESPN":
            Image("ESPNLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 15)
                .padding(.vertical, 2)
                .shadow(color: .black.opacity(selected ? 0 : 0.4), radius: 3)
        default:
            Text(item)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(fg)
        }
    }
}

// MARK: - Encabezado de sección

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.title3.weight(.bold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
