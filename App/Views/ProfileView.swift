import SwiftUI
import UIKit

/// The "Me" tab: identity, address, network, key export, and sign-out.
struct ProfileView: View {
    @EnvironmentObject private var wallet: WalletStore
    @State private var exportedKey: String?
    @State private var showKey = false

    private var username: String {
        let local = (wallet.userEmail ?? "user").split(separator: "@").first.map(String.init) ?? "user"
        let handle = local.filter { $0.isLetter || $0.isNumber }
        return "@" + (handle.isEmpty ? "user" : handle)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    rows
                    Text("Switching changes the active chain (validates wallet_switchEthereumChain). The demo's USDC and gas policy are set up for Base Sepolia — switch back there before paying.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.subtle)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                    footerButtons
                }
                .padding(24)
            }
            .background(Color.white)
            .navigationTitle("Me")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showKey) { keySheet }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Avatar(seed: wallet.userEmail ?? "?", size: 78)
            Text(username).font(.system(size: 22, weight: .bold))
            Text(wallet.userEmail ?? "")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.subtle)
        }
        .padding(.top, 8)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            row(title: "Balance", value: "\(formatUSD(wallet.balance)) USDC")
            Divider()
            Button {
                UIPasteboard.general.string = wallet.address
            } label: {
                row(title: "Address", value: shortAddress(wallet.address), chevron: "doc.on.doc")
            }
            Divider()
            row(title: "Account", value: wallet.isDeployed ? "EIP-7702 delegated" : "EOA")
            Divider()
            row(title: "Gas", value: "Sponsored")
            Divider()
            Menu {
                ForEach(Chain.supported) { chain in
                    Button {
                        Task { await wallet.switchNetwork(to: chain) }
                    } label: {
                        if wallet.activeChainId == chain.id {
                            Label(chain.name, systemImage: "checkmark")
                        } else {
                            Text(chain.name)
                        }
                    }
                }
            } label: {
                row(title: "Network", value: activeChainName, chevron: "chevron.up.chevron.down")
            }
            .disabled(wallet.busy)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task { await wallet.loadActiveChain() }
    }

    private var activeChainName: String {
        Chain.named(wallet.activeChainId)?.name ?? "Base Sepolia"
    }

    private func row(title: String, value: String, chevron: String? = nil) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.subtle)
            if let chevron {
                Image(systemName: chevron).font(.system(size: 13)).foregroundStyle(Theme.subtle)
            }
        }
        .padding(.vertical, 16).padding(.horizontal, 18)
    }

    private var footerButtons: some View {
        VStack(spacing: 12) {
            Button("Export private key") {
                Task {
                    exportedKey = await wallet.exportPrivateKey()
                    showKey = exportedKey != nil
                }
            }
            .buttonStyle(PrimaryButtonStyle(filled: false))

            Button(role: .destructive) {
                Task { await wallet.signOut() }
            } label: {
                Text("Log out").frame(maxWidth: .infinity)
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.red)
            .frame(height: 52)
        }
    }

    private var keySheet: some View {
        VStack(spacing: 18) {
            Image(systemName: "key.fill").font(.system(size: 40)).foregroundStyle(Theme.blue)
            Text("Private key").font(.system(size: 20, weight: .bold))
            Text("Anyone with this key controls your funds. Never share it.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.subtle)
                .multilineTextAlignment(.center)
            Text(exportedKey ?? "")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button("Copy") { UIPasteboard.general.string = exportedKey }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}
