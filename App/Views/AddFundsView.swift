import OpenfortSwift
import SwiftUI
import UIKit

/// Add funds: a cross-chain deposit into the wallet, powered by `OFFunding` (the SwiftUI funding
/// hook). Three ways to complete a deposit, matching what the funding namespace returns:
///   • Address  — a deposit address + QR to send to from anywhere
///   • Wallet   — open a self-custody wallet straight into the transfer
///   • Exchange — a hosted Coinbase pay flow, delivered to the wallet
/// Destination is the user's own wallet, as USDC on Base.
struct AddFundsView: View {
    enum Method: String, CaseIterable, Identifiable {
        case address = "Address"
        case wallet = "Wallet"
        case exchange = "Exchange"
        var id: String { rawValue }
    }

    @EnvironmentObject private var wallet: WalletStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var funding = OFFunding()

    @State private var method: Method = .address
    @State private var source: FundingSource = .polygon
    @State private var copied = false
    @State private var exchangeLoading = false
    @State private var exchangeError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let pm = funding.session?.paymentMethod {
                        results(pm)
                    } else {
                        form
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(Color.white)
            .navigationTitle("Add funds")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                if funding.session?.paymentMethod != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Start over") { funding.reset(); copied = false }
                    }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    // MARK: - Form (no deposit yet)

    private var form: some View {
        VStack(spacing: 18) {
            Picker("How", selection: $method) {
                ForEach(Method.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Text(methodBlurb)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.subtle)
                .multilineTextAlignment(.center)

            if method == .exchange {
                Button { Task { await openCoinbase() } } label: {
                    if exchangeLoading { ProgressView().tint(.white) } else { Text("Pay with Coinbase") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(exchangeLoading || wallet.address == nil)
                if let exchangeError {
                    Text(exchangeError)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(FundingSource.allCases) { opt in
                        selectRow(title: opt.name, subtitle: "Send from \(opt.name)", selected: opt == source) {
                            source = opt
                        }
                    }
                }
                if let error = funding.error {
                    Text(error.localizedDescription)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Button { Task { await submit() } } label: {
                    if funding.loading { ProgressView().tint(.white) } else { Text("Get deposit details") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(funding.loading || wallet.address == nil)
            }

            Text("Deposits settle as USDC on Base, into your wallet.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.subtle)
                .multilineTextAlignment(.center)
        }
    }

    private func selectRow(title: String, subtitle: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.blue : Theme.subtle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.subtle)
                }
                Spacer()
            }
            .padding(14)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? Theme.blue : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Results (deposit address available — Address / Wallet)

    @ViewBuilder
    private func results(_ pm: OFFundingPaymentMethod) -> some View {
        statusPill
        if method == .wallet {
            walletResult(pm)
        } else {
            QRCode(payload: pm.addressUri.isEmpty ? pm.receiverAddress : pm.addressUri)
                .padding(20)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            addressBlock(pm, caption: "Send USDC on \(source.name) to")
        }
        Text("Send any amount above the network fee. Your balance updates once the deposit settles.")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.subtle)
            .multilineTextAlignment(.center)
            .padding(.top, 2)
    }

    @ViewBuilder
    private func walletResult(_ pm: OFFundingPaymentMethod) -> some View {
        ForEach(pm.deeplinks, id: \.url) { link in
            linkButton(label: link.label, url: link.url)
        }
        if !pm.addressUri.isEmpty {
            linkButton(label: "Open in wallet app", url: pm.addressUri)
        }
        addressBlock(pm, caption: pm.deeplinks.isEmpty && pm.addressUri.isEmpty
            ? "Send USDC on \(source.name) to"
            : "Or copy the address")
    }

    private func addressBlock(_ pm: OFFundingPaymentMethod, caption: String) -> some View {
        VStack(spacing: 10) {
            VStack(spacing: 6) {
                Text(caption).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.subtle)
                Text(pm.receiverAddress)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .multilineTextAlignment(.center).padding(.horizontal, 16)
            }
            Button {
                UIPasteboard.general.string = pm.receiverAddress
                copied = true
            } label: {
                Label(copied ? "Copied!" : "Copy address", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(PrimaryButtonStyle(filled: false))
        }
    }

    private func linkButton(label: String, url: String) -> some View {
        Button { if let u = URL(string: url) { openURL(u) } } label: {
            Label(label, systemImage: "arrow.up.forward.app")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 46)
                .foregroundStyle(Theme.blueDark)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var statusPill: some View {
        Label(statusText, systemImage: statusIcon)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(statusColor)
            .padding(.vertical, 7).padding(.horizontal, 12)
            .background(statusColor.opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: - Copy

    private var methodBlurb: String {
        switch method {
        case .address: return "Get an address to send USDC to from any wallet or exchange."
        case .wallet: return "Open a self-custody wallet to send USDC straight into Venma."
        case .exchange: return "Pay with Coinbase — by card or your Coinbase balance — delivered to your wallet."
        }
    }

    private var statusText: String {
        switch funding.status {
        case .requiresPaymentMethod, .none: return "Preparing"
        case .waitingPayment: return "Waiting for your deposit"
        case .processing: return "Processing"
        case .succeeded: return "Funds received"
        case .bounced: return "Deposit refunded"
        case .expired: return "Expired"
        }
    }

    private var statusIcon: String {
        switch funding.status {
        case .succeeded: return "checkmark.circle.fill"
        case .bounced, .expired: return "exclamationmark.circle.fill"
        default: return "clock.fill"
        }
    }

    private var statusColor: Color {
        switch funding.status {
        case .succeeded: return Theme.blue
        case .bounced, .expired: return .red
        default: return Theme.subtle
        }
    }

    // MARK: - Actions

    private func submit() async {
        guard let address = wallet.address else { return }
        let target = OFFundingTarget(chain: EVM.caip2, currency: EVM.usdc, address: address)
        let send = OFFundingSource(chain: source.caip2, currency: source.usdc, amount: "10000000")
        try? await funding.fund(target, .evm(source: send))
    }

    private func openCoinbase() async {
        guard let address = wallet.address else { return }
        exchangeError = nil
        exchangeLoading = true
        defer { exchangeLoading = false }
        let target = OFFundingTarget(chain: EVM.caip2, currency: EVM.usdc, address: address)
        do {
            let session = try await funding.createSession(target)
            let urlString = try await funding.payLink(OFPayLinkParams(sessionId: session.id, amount: "25"))
            if let url = URL(string: urlString) { openURL(url) }
        } catch {
            exchangeError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Source chains offered for a deposit — mainnet USDC → Base mainnet USDC. Addresses are lowercase
/// to match the funding rail's catalog (`/v2/funding/chains`), which compares currencies exactly.
enum FundingSource: String, CaseIterable, Identifiable {
    case polygon
    case arbitrum
    case optimism

    var id: String { rawValue }

    var name: String {
        switch self {
        case .polygon: return "Polygon"
        case .arbitrum: return "Arbitrum"
        case .optimism: return "Optimism"
        }
    }

    var caip2: String {
        switch self {
        case .polygon: return "eip155:137"
        case .arbitrum: return "eip155:42161"
        case .optimism: return "eip155:10"
        }
    }

    var usdc: String {
        switch self {
        case .polygon: return "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359"
        case .arbitrum: return "0xaf88d065e77c8cc2239327c5edb3a432268e5831"
        case .optimism: return "0x0b2c639c533813f4aa9d7837caf62653d097ff85"
        }
    }
}
