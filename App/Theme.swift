import SwiftUI

/// Venmo-style palette and shared styling.
enum Theme {
    /// Venmo signature blue.
    static let blue = Color(red: 0.0, green: 0.55, blue: 1.0)          // #008CFF
    static let blueDark = Color(red: 0.0, green: 0.45, blue: 0.87)     // #0074DE
    static let ink = Color(red: 0.10, green: 0.12, blue: 0.16)         // near-black slate
    static let surface = Color(red: 0.95, green: 0.96, blue: 0.98)     // cool light grey
    static let subtle = Color(red: 0.45, green: 0.49, blue: 0.55)
    static let hairline = Color.black.opacity(0.06)
}

extension Font {
    /// Venmo's amount display — bold and squared (not the rounded face Cash App uses).
    static func amount(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .default)
    }
}

/// Rounded-rectangle button used for primary actions ("Pay", "Request", "Log in").
struct PrimaryButtonStyle: ButtonStyle {
    var filled: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .foregroundStyle(filled ? Color.white : Theme.blueDark)
            .background(filled ? Theme.blue : Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
