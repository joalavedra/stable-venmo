import SwiftUI

/// Venmo's home: a balance card on top of a social feed of payments, read from on-chain
/// USDC `Transfer` events and dressed with their off-chain notes.
struct FeedView: View {
    @EnvironmentObject private var wallet: WalletStore
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
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
                    Text("Your USDC balance and activity, live on Base Sepolia.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.subtle)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
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
            .task(id: wallet.address) { await autoRefresh() }
            .onChange(of: scenePhase) { phase in
                if phase == .active { Task { await wallet.refreshBalance(showLoading: false) } }
            }
            .sheet(isPresented: $showReceive) { ReceiveView(presetAmount: 0) }
        }
    }

    // MARK: - Balance card

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Venma balance")
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
                FeedRow(transfer: transfer) {
                    if let url = URL(string: "https://sepolia.basescan.org/tx/\(transfer.hash)") {
                        openURL(url)
                    }
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

    /// Initial load, then a quiet poll so the balance and feed stay current while home is visible
    /// without the user tapping refresh. Cancelled automatically when the view leaves the screen.
    private func autoRefresh() async {
        await load()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if Task.isCancelled { break }
            await wallet.refreshBalance(showLoading: false)
            if let address = wallet.address,
               let result = try? await RPC.usdcTransfers(of: address) {
                transfers = result
            }
        }
    }
}

/// A single Venmo-style feed entry: who paid whom, the note, the amount, and the social row
/// (public audience + like/comment) that gives the feed its Venmo texture.
private struct FeedRow: View {
    let transfer: USDCTransfer
    var onOpen: () -> Void
    @State private var liked = false

    private var note: String { NoteStore.display(for: transfer.hash, outgoing: transfer.isOutgoing) }
    private var counterparty: String { shortAddress(transfer.counterparty) }

    /// "You paid 0x12…34" / "0x12…34 paid you" with the names in semibold and the verb muted.
    private var actorLine: Text {
        let verb = Text(" paid ").foregroundColor(Theme.subtle)
        let them = Text(counterparty).fontWeight(.semibold).foregroundColor(Theme.ink)
        let you = Text("You").fontWeight(.semibold).foregroundColor(Theme.ink)
        let youLower = Text("you").fontWeight(.semibold).foregroundColor(Theme.ink)
        return transfer.isOutgoing ? (you + verb + them) : (them + verb + youLower)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(seed: transfer.counterparty, size: 44)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        actorLine.font(.system(size: 15))
                        Spacer(minLength: 8)
                        Text((transfer.isOutgoing ? "– " : "+ ") + formatUSD(transfer.amount))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(transfer.isOutgoing ? Theme.ink : Theme.blue)
                    }
                    Text(note)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.ink.opacity(0.85))
                        .lineLimit(2)
                }
                .contentShape(Rectangle())
                .onTapGesture { onOpen() }
                socialRow
            }
        }
        .padding(.vertical, 14)
    }

    private var socialRow: some View {
        HStack(spacing: 14) {
            Label("Public", systemImage: "globe.americas.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.subtle)
            Spacer()
            Button {
                liked.toggle()
            } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .foregroundStyle(liked ? .pink : Theme.subtle)
            }
            .buttonStyle(.plain)
            Image(systemName: "bubble.right")
                .foregroundStyle(Theme.subtle)
        }
        .font(.system(size: 15))
        .padding(.top, 1)
    }
}
