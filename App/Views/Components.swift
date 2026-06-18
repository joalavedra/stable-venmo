import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Branded full-screen splash used for the launching / setting-up states.
struct SplashScreen: View {
    var caption: String
    var body: some View {
        VStack(spacing: 20) {
            LogoMark(size: 72)
            Wordmark(size: 26)
            ProgressView().tint(Theme.blue)
            Text(caption)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.subtle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }
}

/// The blue app-icon badge that stands in for Venmo's logo.
struct LogoMark: View {
    var size: CGFloat = 56
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(Theme.blue)
            .frame(width: size, height: size)
            .overlay(
                Text("V")
                    .font(.system(size: size * 0.58, weight: .heavy, design: .default))
                    .foregroundStyle(.white)
            )
    }
}

/// The lowercase wordmark.
struct Wordmark: View {
    var size: CGFloat = 28
    var body: some View {
        Text("venma")
            .font(.system(size: size, weight: .bold, design: .default))
            .foregroundStyle(Theme.blue)
    }
}

/// Circular monogram avatar derived from an email/identifier, tinted by a deterministic hue so
/// the social feed reads like Venmo's colorful roster of faces.
struct Avatar: View {
    var seed: String
    var size: CGFloat = 36
    private var initial: String { String(seed.first(where: \.isLetter) ?? seed.first ?? "?").uppercased() }
    var body: some View {
        Circle()
            .fill(Self.color(for: seed))
            .frame(width: size, height: size)
            .overlay(
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
            )
    }

    private static let palette: [Color] = [
        Theme.blue,
        Color(red: 0.36, green: 0.42, blue: 0.95),
        Color(red: 0.18, green: 0.70, blue: 0.62),
        Color(red: 0.96, green: 0.55, blue: 0.20),
        Color(red: 0.90, green: 0.36, blue: 0.52),
        Color(red: 0.55, green: 0.38, blue: 0.85),
    ]

    static func color(for seed: String) -> Color {
        let hash = seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palette[hash % palette.count]
    }
}

/// Truncated monospace address, e.g. `0x1234…ab9F`.
func shortAddress(_ address: String?) -> String {
    guard let address, address.count > 12 else { return address ?? "—" }
    return "\(address.prefix(6))…\(address.suffix(4))"
}

/// Renders a QR code for a string payload.
struct QRCode: View {
    var payload: String
    var size: CGFloat = 220
    var body: some View {
        if let image = Self.generate(payload) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }

    private static func generate(_ string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// A floating notification card for an in-flight payment: a spinner while sending, then a
/// success or failure state that auto-dismisses. Replaces the old in-modal result screen so the
/// composer can close the moment "Pay" is tapped.
struct PaymentToastView: View {
    let toast: PaymentToast
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.subtle)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if toast.phase != .sending {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.subtle)
                        .padding(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.hairline)
        )
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var icon: some View {
        switch toast.phase {
        case .sending:
            ProgressView().tint(Theme.blue)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24)).foregroundStyle(Theme.blue)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 24)).foregroundStyle(.red)
        }
    }

    private var title: String {
        switch toast.phase {
        case .sending: return "Sending \(formatUSD(toast.amount))"
        case .success: return "Sent \(formatUSD(toast.amount))"
        case .failed: return "Payment failed"
        }
    }

    private var subtitle: String {
        switch toast.phase {
        case .sending, .success:
            let trimmed = toast.note.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "To \(shortAddress(toast.recipient))" : trimmed
        case .failed:
            return toast.detail ?? "Something went wrong. Please try again."
        }
    }
}

extension View {
    /// Binds an optional error string to a dismissible alert.
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert(
            "Error",
            isPresented: Binding(get: { message.wrappedValue != nil },
                                 set: { if !$0 { message.wrappedValue = nil } })
        ) {
            Button("OK", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

/// USD-style formatting for a USDC `Decimal`.
func formatUSD(_ amount: Decimal, symbol: Bool = true) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = Locale(identifier: "en_US")   // always a "." decimal next to the $ sign
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    let number = formatter.string(from: amount as NSDecimalNumber) ?? "0.00"
    return symbol ? "$\(number)" : number
}

/// The off-chain note that gives Venmo payments their social texture. ERC-20 transfers carry no
/// memo, so notes are kept locally keyed by transaction hash — written when *this* device sends,
/// and read back into the feed. Received payments fall back to a friendly default.
enum NoteStore {
    private static let key = "venmo.notes.v1"

    static func note(for hash: String) -> String? {
        let map = UserDefaults.standard.dictionary(forKey: key) as? [String: String]
        return map?[hash.lowercased()]
    }

    static func save(_ note: String, for hash: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var map = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        map[hash.lowercased()] = trimmed
        UserDefaults.standard.set(map, forKey: key)
    }

    /// A note to display for a transfer: the stored one, or a sensible default by direction.
    static func display(for hash: String, outgoing: Bool) -> String {
        note(for: hash) ?? "Payment"
    }
}
