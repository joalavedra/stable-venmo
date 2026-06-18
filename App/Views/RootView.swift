import SwiftUI

/// Top-level router. Switches between auth, the setup splash, and the home experience based on
/// the SDK's embedded state.
struct RootView: View {
    @EnvironmentObject private var wallet: WalletStore

    var body: some View {
        Group {
            switch wallet.screen {
            case .launching:
                SplashScreen(caption: "Starting up…")
            case .auth:
                AuthView()
            case .settingUp:
                SplashScreen(caption: "Setting up your Venma account…")
            case .home:
                MainView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: wallet.screen)
        .errorAlert($wallet.errorMessage)
        .overlay(alignment: .top) {
            if let toast = wallet.toast {
                PaymentToastView(toast: toast) { wallet.dismissToast() }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: wallet.toast)
    }
}
