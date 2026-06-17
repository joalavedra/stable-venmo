import SwiftUI

/// Venmo's home: a balance card on top of a social feed of payments, read from on-chain
/// USDC `Transfer` events and dressed with their off-chain notes.
struct FeedView: View {
    @EnvironmentObject private var wallet: WalletStore
    @State private var transfers: [USDCTransfer] = []
    @State private var loading = false
    @State private var showReceive = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    balanceCard
                    feedHeader
                    if loading && transfers.isEmpty {
                        ProgressView().tint(Theme.blue).padding(.vertical, 28)
                    } else if transfers.isEmpty {
                        emptyState
                    } else {
                        feedList
                    }
                    if let address = wallet.address {
                        Link("View full history on BaseScan",
                             destination: URL(string: "https://sepolia.basescan.org/address/\(address)")!)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.blueDark)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
            .background(Color.white)
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) { Wordmark(size: 22) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await load() } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                    }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .sheet(isPresented: $showReceive) { ReceiveView(presetAmount: 0) }
        }
    }

    // MARK: - Balance card

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Venmo balance")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Label(wallet.isDeployed ? "Gasless · active" : "Gasless",
                      systemImage: "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.vertical, 5).padding(.horizontal, 9)
                    .background(.white.opacity(0.18))
                    .clipShape(Capsule())
            }
            HStack(spacing: 8) {
                Text(formatUSD(wallet.balance)).font(.amount(40)).foregroundStyle(.white)
                if wallet.balanceLoading {
                    ProgressView().tint(.white).scaleEffect(0.8)
                }
            }
            Button { showReceive = true } label: {
                Label("Receive", systemImage: "qrcode")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.blueDark)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(18)
        .background(
            LinearGradient(colors: [Theme.blue, Theme.blueDark],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var feedHeader: some View {
        HStack {
            Text("Recent activity")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.ink)
            Spacer()
        }
        .padding(.top, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2").font(.system(size: 34)).foregroundStyle(Theme.subtle)
            Text("No activity yet").font(.system(size: 17, weight: .semibold))
            Text("Your payments and requests will show up here.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.subtle)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 28)
    }

    private var feedList: some View {
        VStack(spacing: 0) {
            ForEach(transfers) { transfer in
                Link(destination: URL(string: "https://sepolia.basescan.org/tx/\(transfer.hash)")!) {
                    FeedRow(transfer: transfer)
                }
                if transfer.id != transfers.last?.id {
                    Divider().padding(.leading, 60)
                }
            }
        }
    }

    private func load() async {
        guard let address = wallet.address else { return }
        loading = true
        defer { loading = false }
        await wallet.refreshBalance()
        if let result = try? await RPC.usdcTransfers(of: address) { transfers = result }
    }
}

/// A single Venmo-style feed entry: who paid whom, the note, and the amount.
private struct FeedRow: View {
    let transfer: USDCTransfer

    private var note: String { NoteStore.display(for: transfer.hash, outgoing: transfer.isOutgoing) }
    private var actorLine: String {
        transfer.isOutgoing
            ? "You paid \(shortAddress(transfer.counterparty))"
            : "\(shortAddress(transfer.counterparty)) paid you"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(seed: transfer.counterparty, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(actorLine)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(note)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.subtle)
                    .lineLimit(2)
                Label("Friends", systemImage: "person.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.subtle.opacity(0.8))
                    .padding(.top, 1)
            }
            Spacer(minLength: 8)
            Text((transfer.isOutgoing ? "– " : "+ ") + formatUSD(transfer.amount))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(transfer.isOutgoing ? Theme.ink : Theme.blue)
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}
