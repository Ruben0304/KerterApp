import SwiftUI

/// Estadísticas del partido en vivo: posesión, goles esperados, ocasiones
/// claras, remates a puerta… Cada fila es una barra partida entre los dos
/// equipos, cada mitad del color de su equipo, con el dato a su lado.
struct MatchStatsView: View {
    let stats: [MatchCenterService.StatRow]
    let homeColor: Color
    let awayColor: Color
    /// Sin desplegar solo se ven las principales; el resto entra al pulsar.
    @State private var expanded = false

    private var major: [MatchCenterService.StatRow] { stats.filter(\.isMajor) }
    private var rest: [MatchCenterService.StatRow] { stats.filter { !$0.isMajor } }
    private var visible: [MatchCenterService.StatRow] { expanded ? stats : major }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Divider().overlay(.white.opacity(0.06))
                }
                StatBarRow(row: row, homeColor: homeColor, awayColor: awayColor)
                    .padding(.vertical, 11)
            }

            if !rest.isEmpty {
                Divider().overlay(.white.opacity(0.06))
                Button {
                    withAnimation(.snappy(duration: 0.28)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Text(expanded ? "Ver menos" : "Ver todas las estadísticas")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 1)
        )
    }
}

/// Una fila: dato local · nombre · dato visitante, y debajo la barra partida.
/// La mitad de cada equipo crece desde el centro hacia su lado.
private struct StatBarRow: View {
    let row: MatchCenterService.StatRow
    let homeColor: Color
    let awayColor: Color

    var body: some View {
        VStack(spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.home)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Spacer(minLength: 10)
                Text(row.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 10)
                Text(row.away)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }

            GeometryReader { geo in
                // La barra se parte por donde marque el reparto: el local
                // crece desde la izquierda y el visitante ocupa el resto.
                let gap: CGFloat = 3
                let usable = max(0, geo.size.width - gap)
                HStack(spacing: gap) {
                    Capsule()
                        .fill(homeColor)
                        .frame(width: usable * clamp(row.homeShare))
                    Capsule()
                        .fill(awayColor)
                }
                .frame(height: geo.size.height)
            }
            .frame(height: 6)
        }
        .animation(.snappy(duration: 0.35), value: row.homeShare)
    }

    /// Siempre queda un hilo de color de cada equipo, aunque el reparto sea 0 %.
    private func clamp(_ value: Double) -> CGFloat {
        min(0.97, max(0.03, CGFloat(value)))
    }
}
