import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var email = ""
    @State private var password = ""

    private var isBusy: Bool { auth.state == .authenticating }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 32)
                    wordmark
                    Spacer(minLength: 28)
                    card
                    Spacer(minLength: 20)
                    demoButton
                    Spacer(minLength: 40)
                }
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Prellenamos con la última sesión guardada para no volver a teclear la contraseña.
            if email.isEmpty { email = auth.savedEmail }
            if password.isEmpty { password = auth.savedPassword }
        }
    }

    private var wordmark: some View {
        HStack(spacing: 0) {
            Text("Kerter").fontWeight(.bold)
            Text("+").fontWeight(.black).foregroundStyle(Theme.accent)
        }
        .font(.system(size: 30, design: .rounded))
        .foregroundStyle(.white)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("miKerter")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.55))

                Text("Introduce tu correo para continuar")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.black)

                Text("Inicia sesión en Kerter+ con tu cuenta de miKerter. Si no tienes una, se te propondrá crearla.")
                    .font(.subheadline)
                    .foregroundStyle(.black.opacity(0.55))
            }

            VStack(spacing: 14) {
                PremiumField(placeholder: "Correo electrónico",
                             text: $email, contentType: .email)
                PremiumField(placeholder: "Contraseña",
                             text: $password, isSecure: true, contentType: .password)
            }

            if let error = auth.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.live)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            ContinueButton(title: "Continuar", loading: isBusy) {
                Task { await auth.login(email: email, password: password) }
            }

            Divider().overlay(.black.opacity(0.1))

            VStack(alignment: .leading, spacing: 4) {
                Text("Kerter+ forma parte de la familia de apps Kerter")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.black.opacity(0.75))
                Text("Con miKerter accedes con un solo inicio de sesión a Kerter+ y a tus demás apps Kerter.")
                    .font(.caption)
                    .foregroundStyle(.black.opacity(0.45))
            }
        }
        .padding(28)
        .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.black.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 40, y: 18)
        .environment(\.colorScheme, .light)
        .animation(.smooth, value: auth.errorMessage)
    }

    private var demoButton: some View {
        Button {
            auth.enterDemo()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                Text("Explorar en modo demo")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white.opacity(0.75))
        }
        .buttonStyle(.plain)
    }
}

/// Botón negro en pastilla, como el "Continue" de la referencia.
private struct ContinueButton: View {
    let title: String
    var loading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if loading {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Text(title).font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(.white)
            .background(Color.black, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(loading)
        .opacity(loading ? 0.85 : 1)
    }
}

/// Campo estilo "MyDisney": caja gris clara, borde sutil que se resalta al enfocar.
/// El placeholder se dibuja a mano para garantizar buen contraste (el `TextField` nativo
/// hereda el color de placeholder del `colorScheme` del entorno, que aquí forzamos a claro
/// solo en la tarjeta; sin esto quedaba casi invisible).
private struct PremiumField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var contentType: StyledField.FieldContentType = .generic
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder)
                    .foregroundStyle(Color.black.opacity(0.38))
            }
            Group {
                if isSecure {
                    SecureField("", text: $text)
                } else {
                    TextField("", text: $text)
                }
            }
            .textFieldStyle(.plain)
            .foregroundStyle(.black)
            .focused($isFocused)
            #if os(iOS)
            .keyboardType(contentType == .email ? .emailAddress : .default)
            .textContentType(contentType == .email ? .emailAddress : (contentType == .password ? .password : nil))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
        }
        .font(.system(size: 16, weight: .medium))
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isFocused ? Theme.accent : .black.opacity(0.08), lineWidth: isFocused ? 1.5 : 1)
        )
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
