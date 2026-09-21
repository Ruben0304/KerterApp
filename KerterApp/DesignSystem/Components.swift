import SwiftUI

/// Badge "EN VIVO". El punto pulsa solo cuando `animated` (p. ej. el hero);
/// en rieles va estático para no forzar re-render continuo durante el scroll.
struct LiveBadge: View {
    var animated: Bool = true
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(.white)
                .frame(width: 6, height: 6)
                .opacity(animated && pulse ? 0.4 : 1)
            Text("EN VIVO")
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.5)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.live, in: Capsule())
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

/// Botón principal con estado de carga.
struct PrimaryButton: View {
    let title: String
    var loading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Text(title).font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .foregroundStyle(.white)
            .background(
                LinearGradient(colors: [Theme.accent, Theme.accentDeep],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(loading)
        .opacity(loading ? 0.85 : 1)
    }
}

/// Campo de texto estilizado, adaptado a cada plataforma.
struct StyledField: View {
    let systemImage: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var contentType: FieldContentType = .generic

    enum FieldContentType { case email, password, generic }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .modifier(FieldInputModifier(contentType: contentType))
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .foregroundStyle(.white)
    }
}

/// Ajustes de teclado/autocapitalización (solo aplican en iOS).
private struct FieldInputModifier: ViewModifier {
    let contentType: StyledField.FieldContentType
    func body(content: Content) -> some View {
        #if os(iOS)
        switch contentType {
        case .email:
            content
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .password:
            content
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .generic:
            content
        }
        #else
        content
        #endif
    }
}

// MARK: - Parallax de portada

extension View {
    /// Parallax estilo Apple TV para el fondo de una portada: al bajar la
    /// página se desplaza a `rate` de la velocidad del contenido (queda
    /// "detrás" del texto) y se atenúa un poco. El contenedor debe recortar
    /// (`.clipped()`) para que el fondo desplazado no se salga del marco.
    func heroParallax(rate: CGFloat = 0.5) -> some View {
        visualEffect { content, proxy in
            let scrolled = max(0, -proxy.frame(in: .scrollView(axis: .vertical)).minY)
            let progress = min(1, scrolled / max(proxy.size.height, 1))
            return content
                .offset(y: scrolled * rate)
                .brightness(-0.25 * progress)
        }
    }
}
