import SwiftUI

/// Cartelera: lista de partidos de hoy, cada uno con el grupo de canales que lo
/// transmiten (como en la web de Kerter). Tocar un canal lo reproduce.
struct EventsSection: View {
    let events: [LiveEvent]
    let hPad: CGFloat
    let resolve: (Int) -> Channel?
    let onPlay: (Channel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SectionHeader(title: "Partidos de hoy")
                Text("\(events.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Theme.accent, in: Capsule())
            }
            .padding(.horizontal, hPad)

            VStack(spacing: 10) {
                ForEach(events) { event in
                    EventRow(event: event, resolve: resolve, onPlay: onPlay)
                }
            }
            .padding(.horizontal, hPad)
        }
    }
}

struct EventRow: View {
    let event: LiveEvent
    let resolve: (Int) -> Channel?
    let onPlay: (Channel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let time = event.time, !time.isEmpty {
                    Text(time)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                if let league = event.league {
                    Text(league.uppercased())
                        .font(.caption2.weight(.semibold))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            Text(event.title)
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            // Canales que lo transmiten
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(event.channels) { ec in
                        channelChip(ec)
                    }
                }
            }
        }
        .padding(14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func channelChip(_ ec: EventChannel) -> some View {
        let channel = resolve(ec.id)
        Button {
            if let channel { onPlay(channel) }
        } label: {
            HStack(spacing: 7) {
                CachedImage(url: ec.logo, contentMode: .fit, placeholder: .clear)
                    .frame(width: 20, height: 20)
                Text(ec.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(channel != nil ? Color.black : Color.white.opacity(0.5))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                channel != nil ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.08)),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(channel == nil)
    }
}
