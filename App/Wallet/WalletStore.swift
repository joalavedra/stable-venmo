import Combine
import Foundation
import OpenfortSwift

/// A transient payment notification shown over the whole app while a send is in flight and after
/// it resolves, so the composer can dismiss immediately instead of blocking on an in-modal result.
struct PaymentToast: Identifiable, Equatable {
    enum Phase: Equatable { case sending, success, failed }
    let id = UUID()
    var phase: Phase
    var amount: Decimal
    var recipient: String
    var note: String
    var hash: String?
    var detail: String?
}

/// Single source of truth for the UI. Subscribes to the SDK's embedded-state publisher and
/// derives which screen to show, auto-configuring the wallet once the user authenticates.
@MainActor
final class WalletStore: ObservableObject {
    enum Screen { case launching, auth, settingUp, home }

    @Published private(set) var state: OFEmbeddedState?
    @Published private(set) var address: String?
    @Published private(set) var userEmail: String?
    @Published private(set) var balance: Decimal = 0
    @Published private(set) var accountType: String?
    @Published private(set) var isDeployed = false
    @Published private(set) var balanceLoading = false
    @Published var busy = false
    @Published var otpRequested = false
    @Published var email = ""
    @Published var errorMessage: String?
    @Published var toast: PaymentToast?

    private var cancellables = Set<AnyCancellable>()
    private var lastState: OFEmbeddedState?
    private var didKickConfigure = false

    var screen: Screen {
        // Unwrap first so `.none` resolves to OFEmbeddedState.none, not Optional.none.
        guard let state else { return .launching }
        switch state {
        case .ready: return .home
        case .embeddedSignerNotConfigured, .creatingAccount: return .settingUp
        case .unauthenticated: return .auth
        case .none: return .launching
        }
    }

    init() {
        OFSDK.shared.embeddedStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.onState($0) }
            .store(in: &cancellables)
        Task {
            try? await OpenfortClient.awaitReady()
            await runSmokeTestIfRequested()
        }
    }

    /// Debug-only: when `OF_SMOKE_EMAIL` is set, exercise the exact `requestEmailOtp` path that
    /// was failing with INVALID_CONFIGURATION, and log the outcome. No effect on normal runs.
    private func runSmokeTestIfRequested() async {
        guard let email = ProcessInfo.processInfo.environment["OF_SMOKE_EMAIL"] else { return }
        do {
            try await OpenfortClient.requestEmailOTP(email)
            print("[SMOKE] requestEmailOTP OK for \(email)")
        } catch {
            print("[SMOKE] requestEmailOTP FAILED: \(error)")
        }
    }

    // MARK: - State machine

    /// React only to actual embedded-state transitions, ignoring duplicate republishes.
    private func onState(_ next: OFEmbeddedState?) {
        let changed = next != lastState
        lastState = next
        state = next
        guard changed else { return }

        if next == .embeddedSignerNotConfigured, !didKickConfigure {
            didKickConfigure = true
            Task { await runConfigure() }
        }
        if next == .ready {
            Task { await onReady() }
        }
    }

    private func runConfigure() async {
        do {
            apply(account: try await OpenfortClient.configureWallet())
        } catch {
            didKickConfigure = false
            // A wrong recovery password means this email's embedded signer was created with a
            // different password (e.g. on another build). There's no client-side recovery, so sign
            // out instead of dead-ending on the setup splash, and steer the user to a fresh email.
            if isWrongRecoveryPassword(error) {
                errorMessage = "This email's wallet was set up with a different recovery password. "
                    + "Please log in with a different email."
                await signOut()
            } else {
                errorMessage = friendly(error)
            }
        }
    }

    private func isWrongRecoveryPassword(_ error: Error) -> Bool {
        let raw = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription).lowercased()
        return raw.contains("recovery password")
    }

    private func onReady() async {
        if address == nil { apply(account: try? await OpenfortClient.walletAccount()) }
        userEmail = await OpenfortClient.currentEmail()
        await refreshBalance()
        await refreshDeployment()
    }

    private func apply(account: OFEmbeddedAccount?) {
        guard let account else { return }
        address = account.address
        accountType = account.accountType.rawValue
    }

    /// Reads on-chain code to confirm whether the smart account is deployed yet.
    func refreshDeployment() async {
        guard let address else { return }
        if let deployed = try? await RPC.isContractDeployed(address) { isDeployed = deployed }
    }

    private var balanceSettleTask: Task<Void, Never>?

    /// After a send the transfer may not be mined yet, so the immediate balance read is stale.
    /// Poll a few times so the UI settles to the new value without a manual refresh.
    private func startBalanceSettle() {
        balanceSettleTask?.cancel()
        balanceSettleTask = Task { [weak self] in
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.refreshBalance(showLoading: false)
                await self.refreshDeployment()
            }
        }
    }

    // MARK: - Auth actions

    func sendCode() async {
        await run {
            try await OpenfortClient.requestEmailOTP(email.trimmingCharacters(in: .whitespaces))
            otpRequested = true
        }
    }

    func verify(code: String) async {
        await run {
            try await OpenfortClient.verifyEmailOTP(
                email: email.trimmingCharacters(in: .whitespaces), code: code
            )
            // State publisher drives the rest (settingUp -> home).
        }
    }

    func signOut() async {
        try? await OpenfortClient.logOut()
        otpRequested = false
        didKickConfigure = false
        address = nil
        userEmail = nil
        balance = 0
        email = ""
        toast = nil
        // Drive the UI straight back to auth instead of waiting on the SDK's state publisher,
        // which doesn't reliably emit `.unauthenticated` after logout (so the button looked dead).
        lastState = .unauthenticated
        state = .unauthenticated
    }

    // MARK: - Money

    /// Reads the on-chain USDC balance. `showLoading: false` keeps the spinner off for the silent
    /// background polls so the balance card doesn't flicker on every auto-refresh.
    func refreshBalance(showLoading: Bool = true) async {
        guard let address else { return }
        if showLoading { balanceLoading = true }
        defer { if showLoading { balanceLoading = false } }
        if let fresh = try? await RPC.usdcBalance(of: address) { balance = fresh }
    }

    func exportPrivateKey() async -> String? {
        do { return try await OpenfortClient.exportPrivateKey() }
        catch { errorMessage = friendly(error); return nil }
    }

    /// Fire-and-forget payment. The composer dismisses immediately; the outcome is reported through
    /// a transient toast (sending → success/failed) instead of an in-modal result screen or the
    /// global error alert.
    func pay(to recipient: String, amount: Decimal, note: String, sponsored: Bool) {
        guard let address else { return }
        showToast(PaymentToast(phase: .sending, amount: amount, recipient: recipient, note: note))
        Task {
            do {
                let hash = sponsored
                    ? try await OpenfortClient.sendUSDC(from: address, to: recipient, amount: amount)
                    : try await OpenfortClient.sendUSDCNormal(from: address, to: recipient, amount: amount)
                NoteStore.save(note, for: hash)
                await refreshBalance(showLoading: false)
                await refreshDeployment()
                startBalanceSettle()
                showToast(PaymentToast(
                    phase: .success, amount: amount, recipient: recipient, note: note, hash: hash
                ))
            } catch {
                showToast(PaymentToast(
                    phase: .failed, amount: amount, recipient: recipient, note: note,
                    detail: friendly(error)
                ))
            }
        }
    }

    private var toastDismissTask: Task<Void, Never>?

    /// Shows a toast, auto-dismissing resolved ones (success/failed) after a few seconds. The
    /// "sending" toast stays until its send resolves and replaces it.
    private func showToast(_ next: PaymentToast) {
        toastDismissTask?.cancel()
        toast = next
        guard next.phase != .sending else { return }
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.toast?.id == next.id { self.toast = nil }
        }
    }

    func dismissToast() {
        toastDismissTask?.cancel()
        toast = nil
    }

    // MARK: - Helpers

    private func run(_ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do { try await work() } catch { errorMessage = friendly(error) }
    }

    private func friendly(_ error: Error) -> String {
        let raw = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return raw.isEmpty ? "Something went wrong. Please try again." : raw
    }
}
