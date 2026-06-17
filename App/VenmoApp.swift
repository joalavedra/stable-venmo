import SwiftUI
import OpenfortSwift

/// App entry point. `OFSDK.setupSDK()` must run before any SwiftUI view tries to use the
/// SDK, so it lives in the AppDelegate. `setupSDK()` only *starts* the WebView bridge
/// loading — readiness is awaited separately in `OpenfortClient`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        do {
            try OFSDK.setupSDK()
        } catch {
            // setupSDK rarely throws, but a misconfigured plist surfaces here.
            print("[Venmo] OFSDK.setupSDK failed: \(error)")
        }
        return true
    }
}

@main
struct VenmoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var wallet = WalletStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(wallet)
                .preferredColorScheme(.light)
        }
    }
}
