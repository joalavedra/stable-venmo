import Foundation
import OpenfortSwift

/// Thin async wrapper over `OFSDK`: gates calls on the WebView bridge being ready and exposes
/// the auth, wallet, network, and send operations the app needs as plain `async` functions.
@MainActor
enum OpenfortClient {
    /// Base Sepolia gas-sponsorship policy (MAIN project), so sends are gasless.
    static let gasPolicy = "pol_e62f490a-eb28-45e6-8134-50681c65ee49"

    struct ClientError: LocalizedError { let message: String; var errorDescription: String? { message } }

    // MARK: - Readiness

    /// Blocks until the SDK's WebView bridge finishes loading `openfort.js`, by polling
    /// `isInitialized`.
    static func awaitReady(timeout: TimeInterval = 12) async throws {
        let start = Date()
        while !OFSDK.shared.isInitialized {
            if Date().timeIntervalSince(start) > timeout {
                throw ClientError(message: "Openfort SDK did not become ready in time.")
            }
            try await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    // MARK: - Auth (Email OTP)

    static func requestEmailOTP(_ email: String) async throws {
        try await awaitReady()
        try await OFSDK.shared.requestEmailOtp(params: OFRequestEmailOtpParams(email: email))
    }

    static func verifyEmailOTP(email: String, code: String) async throws {
        _ = try await OFSDK.shared.logInWithEmailOtp(
            params: OFLogInWithEmailOtpParams(email: email, otp: code)
        )
    }

    static func currentEmail() async -> String? {
        (try? await OFSDK.shared.getUser())??.email
    }

    static func logOut() async throws {
        try await OFSDK.shared.logOut()
    }

    // MARK: - Wallet

    /// Creates or recovers the embedded wallet as a **Calibur delegated account** (EIP-7702). The
    /// account address is the user's EOA; with the bundled openfort.js ≥1.3.2 the provider's
    /// `eth_sendTransaction` auto-signs the first-send 7702 authorization server-side (no client-side
    /// viem), so a sponsored send "just works".
    /// Fixed demo recovery password. A production app uses automatic recovery (a backend
    /// encryption-session) or a user-chosen password; a constant keeps this single-device testnet
    /// demo deterministic and reset-proof (a random per-device password breaks recovery whenever
    /// the Keychain is cleared).
    private static let recoveryPassword = "openfort-venmo-demo-recovery-v1"

    @discardableResult
    static func configureWallet() async throws -> OFEmbeddedAccount? {
        // Delegated/smart accounts are chain-scoped, so pass the chainId (unlike a bare EOA).
        try await OFSDK.shared.configure(
            params: OFEmbeddedAccountConfigureParams(
                chainId: EVM.chainId,
                recoveryParams: OFRecoveryParamsDTO(
                    recoveryMethod: .password,
                    password: recoveryPassword
                ),
                accountType: .delegatedAccount
            )
        )
    }

    /// The first embedded account (used when the wallet is already configured on app relaunch
    /// and we never called `configure` this session).
    static func walletAccount() async throws -> OFEmbeddedAccount? {
        try await OFSDK.shared.list()?.first
    }

    static func exportPrivateKey() async throws -> String? {
        try await OFSDK.shared.exportPrivateKey()
    }

    // MARK: - Network (switch chains)

    /// Reads the provider's active chain id (decimal) via `eth_chainId`.
    static func currentChainId() async throws -> Int? {
        let provider = try await OFSDK.shared.getEthereumProvider(params: OFGetEthereumProviderParams())
        guard let provider else { throw ClientError(message: "No Ethereum provider.") }
        guard let hex = try await provider.request(method: "eth_chainId", params: []) else { return nil }
        return Int(hex.dropFirst(2), radix: 16)
    }

    /// Switches the active chain via `wallet_switchEthereumChain`, then reads `eth_chainId` back to
    /// confirm. Returns the confirmed chain id.
    @discardableResult
    static func switchChain(toHex hex: String) async throws -> Int? {
        let provider = try await OFSDK.shared.getEthereumProvider(params: OFGetEthereumProviderParams())
        guard let provider else { throw ClientError(message: "No Ethereum provider.") }
        _ = try await provider.request(method: "wallet_switchEthereumChain", params: [["chainId": hex]])
        guard let confirmed = try await provider.request(method: "eth_chainId", params: []) else { return nil }
        return Int(confirmed.dropFirst(2), radix: 16)
    }

    // MARK: - Send (gasless USDC transfer via EIP-7702)

    /// Sends USDC gaslessly through the EIP-1193 provider with a sponsorship policy. On a Calibur
    /// delegated account the bundled openfort.js (≥1.3.2) auto-signs the first-send 7702
    /// authorization and the transaction-intent hash via the embedded signer, and the
    /// bundler + paymaster cover gas — no client-side viem. Returns the transaction hash.
    static func sendUSDC(from: String, to: String, amount: Decimal) async throws -> String {
        let provider = try await OFSDK.shared.getEthereumProvider(
            params: OFGetEthereumProviderParams(policy: gasPolicy)
        )
        guard let provider else { throw ClientError(message: "No Ethereum provider.") }
        let tx: [String: String] = [
            "from": from,
            "to": EVM.usdc,
            "value": "0x0",
            "data": EVM.transferCalldata(to: to, amountBaseUnits: EVM.toBaseUnits(amount)),
            // no gas/gasPrice — the policy sponsors it
        ]
        guard let hash = try await provider.request(method: "eth_sendTransaction", params: [tx]) else {
            throw ClientError(message: "Transaction returned no hash.")
        }
        return hash
    }

    /// Sends USDC as a **normal, non-sponsored** transaction through the EIP-1193 provider with no
    /// gas policy — the account pays its own gas (requires Base Sepolia ETH). Returns the hash.
    static func sendUSDCNormal(from: String, to: String, amount: Decimal) async throws -> String {
        let provider = try await OFSDK.shared.getEthereumProvider(params: OFGetEthereumProviderParams())
        guard let provider else { throw ClientError(message: "No Ethereum provider.") }
        // Validate the SDK's switch-chain path: pin the active chain to Base Sepolia before sending
        // (a no-op for a delegated account already scoped to it, but it exercises the RPC).
        _ = try await provider.request(
            method: "wallet_switchEthereumChain",
            params: [["chainId": EVM.chainHex]]
        )
        let tx: [String: String] = [
            "from": from,
            "to": EVM.usdc,
            "value": "0x0",
            "data": EVM.transferCalldata(to: to, amountBaseUnits: EVM.toBaseUnits(amount)),
        ]
        guard let hash = try await provider.request(method: "eth_sendTransaction", params: [tx]) else {
            throw ClientError(message: "Transaction returned no hash.")
        }
        return hash
    }
}
