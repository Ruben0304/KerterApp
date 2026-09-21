import SwiftUI

enum Theme {
    /// El acento del sistema (azul en iOS, el que tenga elegido el usuario en
    /// macOS) — sin color de marca propio, para que todo salga por defecto.
    static let accent = Color.accentColor
    static let accentDeep = Color.accentColor.mix(with: .black, by: 0.2)
    static let live = Color(hex: 0xFF3B30)

    /// Gradiente de marca para el hero del login.
    static let brandGradient = LinearGradient(
        colors: [Color(hex: 0x0C3A2C), Color(hex: 0x0A1013), Color(hex: 0x06222A)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let posterGradient = LinearGradient(
        colors: [Color(hex: 0x1B4A3A), Color(hex: 0x0F2A34)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let cardCorner: CGFloat = 18
    static let controlCorner: CGFloat = 12
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    /// "cd0000" / "#CD0000" → Color. `brightness` < 1 lo oscurece.
    init?(hexString: String?, brightness: Double = 1) {
        guard let raw = hexString?.trimmingCharacters(in: CharacterSet(charactersIn: "# ")),
              raw.count == 6, let v = UInt(raw, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((v >> 16) & 0xFF) / 255 * brightness,
            green: Double((v >> 8) & 0xFF) / 255 * brightness,
            blue: Double(v & 0xFF) / 255 * brightness
        )
    }
}

/// Iniciales para los placeholders de canal ("Kerter Deportes 1" → "KD").
func initials(from name: String) -> String {
    let words = name.split(separator: " ").prefix(2)
    let letters = words.compactMap { $0.first }.map(String.init)
    return letters.joined().uppercased()
}
