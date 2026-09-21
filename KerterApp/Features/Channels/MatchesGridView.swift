import SwiftUI

/// Pantalla simple: cuadrícula de partidos de la cartelera filtrados por canal
/// (barra superior: Kerter+, DAZN, ESPN) o por competición.
struct MatchesGridView: View {
    let filter: MatchFilter
    let items: [EventItem]
    /// Sin botón "Atrás": se vuelve con "Para ti" en la pastilla de arriba.
    let onSelect: (EventItem) -> Void

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    #endif

    /// La columna debe tener, como mínimo, el mismo ancho que su tarjeta.
    /// Antes podía medir 290 mientras `EventCard` medía 340, por lo que dos
    /// cards acababan solapándose al filtrar por una marca.
    private var cardWidth: CGFloat? { compact ? nil : 340 }
    private var columns: [GridItem] {
        if compact {
            return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        }
        return [GridItem(.adaptive(minimum: 340, maximum: 380), spacing: 24)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                if items.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: "sportscourt",
                                           description: Text("Cuando la cartelera tenga partidos aparecerán aquí."))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: compact ? 16 : 28) {
                        ForEach(items) { item in
                            EventCard(channel: item.card, action: { onSelect(item) }, width: cardWidth)
                        }
                    }
                }
            }
            .padding(.horizontal, compact ? 16 : 32)
            .padding(.top, compact ? 60 : 84)   // bajo la barra flotante de arriba
            .padding(.bottom, 32)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            brand

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(1)
                Text(items.count == 1 ? "1 partido" : "\(items.count) partidos")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var brand: some View {
        switch filter {
        case .competition(let competition):
            CachedImage(url: competition.logoURL, contentMode: .fit, placeholder: .clear)
                .frame(width: 52, height: 52)
                .padding(6)
                .background(Circle().fill(Color(hex: 0x15181F)))
        case .channel(let name) where name == "ESPN":
            Image("ESPNLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 26)
        case .channel:
            EmptyView()
        }
    }

    private var title: String {
        switch filter {
        case .competition(let competition): return competition.name
        case .channel(let name): return name == "ESPN" ? "Partidos" : "Partidos en \(name)"
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .competition(let competition): return "No hay partidos de \(competition.name) hoy"
        case .channel(let name): return "No hay partidos en \(name) hoy"
        }
    }
}
