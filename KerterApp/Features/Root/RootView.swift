import SwiftUI

struct RootView: View {
    @EnvironmentObject private var auth: AuthManager

    var body: some View {
        Group {
            if auth.isSignedIn {
                MainView(auth: auth)
            } else {
                LoginView()
            }
        }
        .animation(.smooth(duration: 0.35), value: auth.isSignedIn)
    }
}
