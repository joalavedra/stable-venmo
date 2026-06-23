import SwiftUI
import UIKit

/// Email-OTP sign-in, styled after Venmo's minimal onboarding.
struct AuthView: View {
    @EnvironmentObject private var wallet: WalletStore
    @State private var code = ""
    @State private var lastSubmitted = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            LogoMark(size: 64)
            Wordmark(size: 30)
            if wallet.otpRequested {
                codeStep
            } else {
                emailStep
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .onAppear { focused = true }
    }

    // MARK: - Step 1: email

    private var emailStep: some View {
        VStack(spacing: 20) {
            Text("Log in to Venma")
                .font(.system(size: 26, weight: .bold))
            TextField("you@email.com", text: $wallet.email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 18, weight: .medium))
                .padding(.vertical, 16)
                .padding(.horizontal, 18)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .focused($focused)

            Button {
                Task { await wallet.sendCode() }
            } label: {
                Text(wallet.busy ? "Sending…" : "Send code")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(wallet.busy || !isValidEmail)
            .opacity(isValidEmail ? 1 : 0.5)
        }
    }

    private var isValidEmail: Bool {
        let value = wallet.email.trimmingCharacters(in: .whitespaces)
        return value.contains("@") && value.contains(".")
    }

    // MARK: - Step 2: code

    private var codeStep: some View {
        VStack(spacing: 20) {
            Text("Enter the code")
                .font(.system(size: 26, weight: .bold))
            Text("Sent to \(wallet.email)")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.subtle)

            OTPBoxes(code: code)
                .overlay(
                    TextField("", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($focused)
                        .opacity(0.02)
                        .onChange(of: code) { handleCodeChange($0) }
                )
                .contentShape(Rectangle())
                .onTapGesture { focused = true }

            Button { pasteCode() } label: {
                Label("Paste code", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(PrimaryButtonStyle(filled: false))

            Button("Change email") {
                wallet.otpRequested = false
                code = ""
                lastSubmitted = ""
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.blueDark)
        }
        .onAppear { focused = true }
    }

    private func pasteCode() {
        let digits = String((UIPasteboard.general.string ?? "").filter(\.isNumber).prefix(6))
        guard !digits.isEmpty else { return }
        code = digits
        handleCodeChange(digits)
    }

    private func handleCodeChange(_ value: String) {
        let digits = String(value.filter(\.isNumber).prefix(6))
        if digits != value { code = digits }
        // Re-arm once edited below 6 digits so a corrected code can resubmit.
        if digits.count < 6 { lastSubmitted = "" }
        // Submit each complete code at most once. onChange can fire twice for a single entry
        // (and .oneTimeCode autofill re-sets it), which double-verified a now-consumed OTP and
        // surfaced a spurious "incorrect code" even though the first verify had succeeded.
        if digits.count == 6, digits != lastSubmitted {
            lastSubmitted = digits
            Task { await wallet.verify(code: digits) }
        }
    }
}

/// Six-box OTP display backed by an invisible text field.
private struct OTPBoxes: View {
    var code: String
    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<6, id: \.self) { index in
                let char = index < code.count ? String(Array(code)[index]) : ""
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.surface)
                    .frame(width: 46, height: 58)
                    .overlay(
                        Text(char)
                            .font(.system(size: 24, weight: .bold))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(index == code.count ? Theme.blue : .clear, lineWidth: 2)
                    )
            }
        }
    }
}
