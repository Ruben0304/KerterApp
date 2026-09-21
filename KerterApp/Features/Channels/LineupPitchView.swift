import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// El once de un solo equipo. La portería propia queda abajo y el ataque
/// arriba, igual que en una pizarra táctica.
struct LineupPitchView: View {
    let team: MatchCenterService.TeamLineup
    let teamColor: Color

    var body: some View {
        GeometryReader { geo in
            let scale = min(1.15, max(0.72, geo.size.width / 480))

            ZStack {
                PitchBackground()

                ForEach(team.starters) { player in
                    PlayerToken(player: player, color: teamColor, scale: scale)
                        .position(
                            x: player.x * geo.size.width,
                            y: geo.size.height * (0.94 - player.y * 0.88)
                        )
                }
            }
        }
        .aspectRatio(1.38, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
    }
}

// MARK: - Campo

private struct PitchBackground: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .linearGradient(
                Gradient(colors: [Color(hex: 0x328744), Color(hex: 0x28783B)]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)
            ))

            let stripeHeight = size.height / 8
            for row in stride(from: 0, to: 8, by: 2) {
                let stripe = CGRect(x: 0, y: CGFloat(row) * stripeHeight,
                                    width: size.width, height: stripeHeight)
                context.fill(Path(stripe), with: .color(.white.opacity(0.035)))
            }

            let paint = Color.white.opacity(0.42)
            let lineWidth = max(1, size.width * 0.003)
            let inset = size.width * 0.045
            let field = rect.insetBy(dx: inset, dy: inset)

            func stroke(_ path: Path) {
                context.stroke(path, with: .color(paint), lineWidth: lineWidth)
            }

            stroke(Path(field))

            var halfway = Path()
            halfway.move(to: CGPoint(x: field.minX, y: rect.midY))
            halfway.addLine(to: CGPoint(x: field.maxX, y: rect.midY))
            stroke(halfway)

            let centerRadius = size.height * 0.12
            stroke(Path(ellipseIn: CGRect(x: rect.midX - centerRadius,
                                          y: rect.midY - centerRadius,
                                          width: centerRadius * 2,
                                          height: centerRadius * 2)))
            let dotRadius = max(1.5, lineWidth * 1.2)
            context.fill(Path(ellipseIn: CGRect(x: rect.midX - dotRadius,
                                                y: rect.midY - dotRadius,
                                                width: dotRadius * 2,
                                                height: dotRadius * 2)),
                         with: .color(paint))

            for top in [true, false] {
                let boxWidth = field.width * 0.48
                let boxHeight = field.height * 0.17
                let boxY = top ? field.minY : field.maxY - boxHeight
                stroke(Path(CGRect(x: rect.midX - boxWidth / 2, y: boxY,
                                   width: boxWidth, height: boxHeight)))

                let goalAreaWidth = field.width * 0.22
                let goalAreaHeight = field.height * 0.075
                let goalAreaY = top ? field.minY : field.maxY - goalAreaHeight
                stroke(Path(CGRect(x: rect.midX - goalAreaWidth / 2, y: goalAreaY,
                                   width: goalAreaWidth, height: goalAreaHeight)))

                let goalWidth = field.width * 0.15
                let goalDepth = inset * 0.5
                let goalY = top ? field.minY - goalDepth : field.maxY
                stroke(Path(CGRect(x: rect.midX - goalWidth / 2, y: goalY,
                                   width: goalWidth, height: goalDepth)))

                let spotY = top ? field.minY + field.height * 0.115
                                : field.maxY - field.height * 0.115
                context.fill(Path(ellipseIn: CGRect(x: rect.midX - dotRadius,
                                                    y: spotY - dotRadius,
                                                    width: dotRadius * 2,
                                                    height: dotRadius * 2)),
                             with: .color(paint))
            }
        }
        .drawingGroup()
    }
}

// MARK: - Titular

private struct PlayerToken: View {
    let player: MatchCenterService.Player
    let color: Color
    let scale: CGFloat

    private var face: CGFloat { 58 * scale }

    var body: some View {
        VStack(spacing: 3 * scale) {
            ZStack {
                photo

                if let jersey = player.jersey {
                    Text(jersey)
                        .font(.system(size: 11 * scale, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.black)
                        .frame(minWidth: 22 * scale, minHeight: 22 * scale)
                        .background(.white, in: Circle())
                        .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 1))
                        .offset(x: -face * 0.43, y: -face * 0.36)
                }

                if let rating = player.rating {
                    RatingChip(rating: rating, scale: scale)
                        .offset(x: -face * 0.34, y: face * 0.38)
                }

                eventBadges
                    .offset(x: face * 0.43, y: -face * 0.32)
            }
            .frame(width: face + 18 * scale, height: face + 5 * scale)

            Text(player.shortName)
                .font(.system(size: 12 * scale, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
        }
        .frame(width: 88 * scale)
    }

    private var photo: some View {
        CachedImage(url: player.photo, contentMode: .fill, placeholder: .clear)
            .frame(width: face, height: face)
            .background(
                Circle().fill(
                    LinearGradient(colors: [color.opacity(0.95), color.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom)
                )
            )
            .overlay {
                if player.photo == nil {
                    Image(systemName: "person.fill")
                        .font(.system(size: 25 * scale))
                        .foregroundStyle(color.isLight ? .black.opacity(0.55) : .white.opacity(0.8))
                }
            }
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2 * scale))
            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
    }

    @ViewBuilder
    private var eventBadges: some View {
        VStack(spacing: 2 * scale) {
            if player.goals > 0 {
                eventBadge(systemName: "soccerball", tint: .white, foreground: .black)
            }
            if player.redCards > 0 {
                cardBadge(Color(hex: 0xE0342B))
            } else if player.yellowCards > 0 {
                cardBadge(Color(hex: 0xF7C325))
            }
            if player.subbedOut != nil {
                eventBadge(systemName: "arrow.down", tint: .white,
                           foreground: Color(hex: 0xE0342B))
            }
        }
    }

    private func eventBadge(systemName: String, tint: Color, foreground: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 10 * scale, weight: .bold))
            .foregroundStyle(foreground)
            .frame(width: 20 * scale, height: 20 * scale)
            .background(tint, in: Circle())
            .overlay(Circle().strokeBorder(.black.opacity(0.3), lineWidth: 1))
    }

    private func cardBadge(_ tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 2 * scale)
            .fill(tint)
            .frame(width: 11 * scale, height: 15 * scale)
            .padding(4 * scale)
            .background(.white, in: Circle())
            .overlay(Circle().strokeBorder(.black.opacity(0.3), lineWidth: 1))
    }
}

struct RatingChip: View {
    let rating: Double
    var scale: CGFloat = 1

    private var tint: Color {
        switch rating {
        case 8...:   return Color(hex: 0x1689E8)
        case 7..<8:  return Color(hex: 0x43AE51)
        case 6..<7:  return Color(hex: 0xFFB400)
        default:     return Color(hex: 0xF18B17)
        }
    }

    var body: some View {
        Text(rating.formatted(.number.precision(.fractionLength(1))))
            .font(.system(size: 11 * scale, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5 * scale)
            .padding(.vertical, 2 * scale)
            .background(tint, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.45), lineWidth: 0.75))
    }
}

// MARK: - Color

extension Color {
    var rgb: (r: CGFloat, g: CGFloat, b: CGFloat) {
        #if os(macOS)
        let native = NSColor(self).usingColorSpace(.sRGB)
        return (native?.redComponent ?? 0, native?.greenComponent ?? 0, native?.blueComponent ?? 0)
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b)
        #endif
    }

    var isLight: Bool {
        let c = rgb
        return (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) > 0.72
    }

    func isDistinct(from other: Color) -> Bool {
        let a = rgb, b = other.rgb
        let distance = abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
        return distance > 0.45
    }
}
