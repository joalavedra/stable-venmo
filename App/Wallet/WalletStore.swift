import Combine
import Foundation
import OpenfortSwift

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
    @Published private(set) var activeChainId: Int?
    @Published private(set) var balanceLoading = false
    @Published var busy = false
    @Published var otpRequested = false
    @Published var email = ""
    @Published var errorMessage: String?

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
            errorMessage = friendly(error)
            didKickConfigure = false
        }
    }

    private func onReady() async {
        if address == nil { apply(account: try? await OpenfortClient.walletAccount()) }
        userEmail = await OpenfortClient.currentEmail()
        await refreshBalance()
        await refreshDeployment()
        await loadActiveChain()
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
                await self.refreshBalance()
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
        activeChainId = nil
    }

    // MARK: - Money

    func refreshBalance() async {
        guard let address else { return }
        balanceLoading = true
        defer { balanceLoading = false }
        if let fresh = try? await RPC.usdcBalance(of: address) { balance = fresh }
    }

    func exportPrivateKey() async -> String? {
        do { return try await OpenfortClient.exportPrivateKey() }
        catch { errorMessage = friendly(error); return nil }
    }

    // MARK: - Network

    func loadActiveChain() async {
        activeChainId = try? await OpenfortClient.currentChainId()
    }

    /// Switches the embedded wallet's active chain (validates `wallet_switchEthereumChain`).
    func switchNetwork(to chain: Chain) async {
        await run {
            activeChainId = try await OpenfortClient.switchChain(toHex: chain.hex) ?? chain.id
        }
    }

    func send(to recipient: String, amount: Decimal, sponsored: Bool) async -> String? {
        guard let address else { return nil }
        busy = true
        defer { busy = false }
        do {
            let hash = sponsored
                ? try await OpenfortClient.sendUSDC(from: address, to: recipient, amount: amount)
                : try await OpenfortClient.sendUSDCNormal(from: address, to: recipient, amount: amount)
            await refreshBalance()
            await refreshDeployment()
            startBalanceSettle()
            return hash
        } catch {
            errorMessage = friendly(error)
            return nil
        }
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
