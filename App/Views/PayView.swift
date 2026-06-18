import SwiftUI
import UIKit

/// Venmo's "Pay or Request" composer: a recipient, a big amount driven by an always-visible
/// number pad, a note ("What's it for?"), and the two signature actions. Paying sends USDC
/// gaslessly via EIP-7702; requesting surfaces a shareable QR so the other side can pay you.
struct PayView: View {
    @EnvironmentObject private var wallet: WalletStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var noteFocused: Bool

    var presetAmount: Decimal
    @State private var recipient = ""
    @State private var amountText: String
    @State private var note = ""
    @State private var sponsored = true
    @State private var requested = false

    init(presetAmount: Decimal) {
        self.presetAmount = presetAmount
        _amountText = State(initialValue: presetAmount > 0 ? formatUSD(presetAmount, symbol: false) : "0")
    }

    private var amount: Decimal { Decimal(string: amountText) ?? 0 }
    private var validRecipient: Bool { recipient.hasPrefix("0x") && recipient.count == 42 }
    private var canPay: Bool { amount > 0 && validRecipient }
    private var canRequest: Bool { amount > 0 }

    var body: some View {
        NavigationStack {
            Group {
                if requested {
                    requestCreated
                } else {
                    composer
                }
            }
            .navigationTitle(requested ? "" : "Pay or Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer(); Button("Done") { noteFocused = false }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 0) {
            recipientField
                .padding(.horizontal, 20)
                .padding(.top, 8)
            Spacer(minLength: 12)
            amountDisplay
            noteField
                .padding(.horizontal, 20)
                .padding(.top, 14)
            Spacer(minLength: 12)
            if !noteFocused {
                AmountKeypad(amount: $amountText).padding(.horizontal, 12)
                gaslessToggle
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                actionButtons
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }
        }
    }

    private var recipientField: some View {
        HStack(spacing: 10) {
            Text("To").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.subtle)
            TextField("wallet address 0x…", text: $recipient)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            PasteButton(payloadType: String.self) { items in
                guard let text = items.first else { return }
                recipient = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .labelStyle(.iconOnly)
            .tint(Theme.blue)
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var amountDisplay: some View {
        Text("$" + amountText)
            .font(.system(size: 60, weight: .bold))
            .foregroundStyle(amount > 0 ? Theme.ink : Theme.subtle)
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .padding(.horizontal, 20)
            .contentTransition(.numericText())
            .animation(.snappy, value: amountText)
    }

    private var noteField: some View {
        HStack {
            TextField("What's it for?", text: $note)
                .font(.system(size: 16, weight: .medium))
                .multilineTextAlignment(.center)
                .focused($noteFocused)
            if note.isEmpty && !noteFocused {
                Image(systemName: "face.smiling").foregroundStyle(Theme.subtle)
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(Theme.surface)
        .clipShape(Capsule())
    }

    private var gaslessToggle: some View {
        Picker("Gas", selection: $sponsored) {
            Text("Gasless (7702)").tag(true)
            Text("Pay own gas").tag(false)
        }
        .pickerStyle(.segmented)
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button("Request") { requested = true }
                .buttonStyle(PrimaryButtonStyle(filled: false))
                .disabled(!canRequest)
                .opacity(canRequest ? 1 : 0.5)
            Button {
                wallet.pay(to: recipient, amount: amount, note: note, sponsored: sponsored)
                dismiss()
            } label: {
                Text("Pay")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canPay)
            .opacity(canPay ? 1 : 0.5)
        }
    }

    // MARK: - Results

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

/// Venmo-style numeric keypad that edits a decimal-amount string in place.
struct AmountKeypad: View {
    @Binding var amount: String
    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "0", "⌫"]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 4) {
            ForEach(keys, id: \.self) { key in
                Button { tap(key) } label: {
                    Text(key)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .contentShape(Rectangle())
                }
            }
        }
    }

    private func tap(_ key: String) {
        var value = amount
        switch key {
        case "⌫":
            value = String(value.dropLast())
            if value.isEmpty { value = "0" }
        case ".":
            if !value.contains(".") { value += "." }
        default:
            if value == "0" { value = key } else { value += key }
        }
        if let dot = value.firstIndex(of: "."), value.distance(from: dot, to: value.endIndex) > 3 {
            return // cap at 2 decimal places
        }
        amount = value
    }
}
