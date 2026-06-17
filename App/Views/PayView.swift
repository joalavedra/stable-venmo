import SwiftUI
import UIKit

/// Venmo's "Pay or Request" composer: an amount, a note ("What's it for?"), a recipient, and the
/// two signature actions. Paying sends USDC gaslessly via EIP-7702; requesting surfaces a
/// shareable QR so the other side can pay you.
struct PayView: View {
    @EnvironmentObject private var wallet: WalletStore
    @Environment(\.dismiss) private var dismiss

    var presetAmount: Decimal
    @State private var recipient = ""
    @State private var amountText: String
    @State private var note = ""
    @State private var sponsored = true
    @State private var txHash: String?
    @State private var requested = false

    init(presetAmount: Decimal) {
        self.presetAmount = presetAmount
        _amountText = State(initialValue: presetAmount > 0 ? formatUSD(presetAmount, symbol: false) : "")
    }

    private var amount: Decimal { Decimal(string: amountText) ?? 0 }
    private var validRecipient: Bool { recipient.hasPrefix("0x") && recipient.count == 42 }
    private var canPay: Bool { !wallet.busy && amount > 0 && validRecipient }
    private var canRequest: Bool { amount > 0 }

    var body: some View {
        NavigationStack {
            Group {
                if let txHash {
                    paySuccess(txHash)
                } else if requested {
                    requestCreated
                } else {
                    form
                }
            }
            .navigationTitle(txHash != nil || requested ? "" : "Pay or Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDragIndicator(.visible)
    }

    // MARK: - Form

    private var form: some View {
        ScrollView {
            VStack(spacing: 22) {
                amountField
                noteField
                recipientField
                gaslessToggle
                actionButtons
            }
            .padding(24)
        }
    }

    private var amountField: some View {
        HStack(spacing: 2) {
            Text("$").font(.amount(44)).foregroundStyle(amount > 0 ? Theme.ink : Theme.subtle)
            TextField("0", text: $amountText)
                .font(.amount(44))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var noteField: some View {
        HStack {
            TextField("What's it for?", text: $note)
                .font(.system(size: 17, weight: .medium))
            if note.isEmpty {
                Image(systemName: "face.smiling").foregroundStyle(Theme.subtle)
            }
        }
        .padding(.vertical, 14).padding(.horizontal, 16)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var recipientField: some View {
        VStack(spacing: 4) {
            Text("To (wallet address)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.subtle)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                TextField("0x…", text: $recipient)
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button {
                    recipient = UIPasteboard.general.string ?? recipient
                } label: {
                    Image(systemName: "doc.on.clipboard").foregroundStyle(Theme.blueDark)
                }
            }
            .padding(.vertical, 14).padding(.horizontal, 16)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var gaslessToggle: some View {
        VStack(spacing: 8) {
            Picker("Gas", selection: $sponsored) {
                Text("Gasless (7702)").tag(true)
                Text("Pay own gas").tag(false)
            }
            .pickerStyle(.segmented)
            Label(
                sponsored
                    ? "Gasless via EIP-7702 — sponsored, no ETH needed"
                    : "Normal transaction — your wallet pays gas (needs ETH)",
                systemImage: sponsored ? "bolt.fill" : "fuelpump.fill"
            )
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(sponsored ? Theme.blueDark : Theme.subtle)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button("Request") { requested = true }
                .buttonStyle(PrimaryButtonStyle(filled: false))
                .disabled(!canRequest)
                .opacity(canRequest ? 1 : 0.5)
            Button {
                Task {
                    let hash = await wallet.send(to: recipient, amount: amount, sponsored: sponsored)
                    if let hash { NoteStore.save(note, for: hash) }
                    txHash = hash
                }
            } label: {
                Text(wallet.busy ? "Paying…" : "Pay")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canPay)
            .opacity(canPay ? 1 : 0.5)
        }
    }

    // MARK: - Results

    private func paySuccess(_ hash: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60)).foregroundStyle(Theme.blue)
            Text("You paid \(formatUSD(amount))")
                .font(.system(size: 23, weight: .bold))
            if !note.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(note).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.subtle)
            }
            Label(
                sponsored ? "Gasless · EIP-7702 sponsored" : "Normal · wallet paid gas",
                systemImage: sponsored ? "bolt.fill" : "fuelpump.fill"
            )
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(sponsored ? Theme.blueDark : Theme.subtle)
            Link("View on BaseScan", destination: URL(string: "https://sepolia.basescan.org/tx/\(hash)")!)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.blueDark)
            Spacer()
            Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(24)
    }

    private var requestCreated: some View {
        VStack(spacing: 18) {
            Text("Requesting \(formatUSD(amount))")
                .font(.system(size: 22, weight: .bold))
            if !note.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(note).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.subtle)
            }
            QRCode(payload: wallet.address ?? "")
                .padding(18)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text("Have them scan to pay your USDC address (Base Sepolia).")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.subtle)
                .multilineTextAlignment(.center)
            Button {
                UIPasteboard.general.string = wallet.address
            } label: {
                Label("Copy address", systemImage: "doc.on.doc")
            }
            .buttonStyle(PrimaryButtonStyle(filled: false))
            Spacer()
            Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(24)
    }
}
