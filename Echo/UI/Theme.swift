import SwiftUI

/// Echo's design tokens: warm graphite surfaces, hairline strokes, and one
/// coral accent reserved for "live" things (waveform, recording, status dots).
extension Color {
    static let echoBase = dynamic(dark: NSColor(hex: 0x1C1B21), light: NSColor(hex: 0xF2F1F5))
    static let echoCard = dynamic(dark: NSColor(hex: 0x26252C), light: NSColor.white)
    static let echoCardHover = dynamic(dark: NSColor(hex: 0x2D2C34), light: NSColor(hex: 0xEBEAEF))
    static let echoHairline = dynamic(
        dark: NSColor.white.withAlphaComponent(0.08),
        light: NSColor.black.withAlphaComponent(0.08)
    )
    static let echoText = dynamic(dark: NSColor(hex: 0xF2F0F5), light: NSColor(hex: 0x1D1C22))
    static let echoSecondary = dynamic(dark: NSColor(hex: 0x98959F), light: NSColor(hex: 0x6E6B78))
    static let echoCoral = Color(nsColor: NSColor(hex: 0xFF5C5C))

    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

/// Echo's type system: Inter for UI, JetBrains Mono for data. Both are bundled
/// (Resources/Fonts, registered via ATSApplicationFontsPath).
enum EchoFontWeight {
    case regular, medium, semibold, bold

    var interName: String {
        switch self {
        case .regular: return "Inter-Regular"
        case .medium: return "Inter-Medium"
        case .semibold: return "Inter-SemiBold"
        case .bold: return "Inter-Bold"
        }
    }
}

extension Font {
    static func echo(_ size: CGFloat, _ weight: EchoFontWeight = .regular) -> Font {
        .custom(weight.interName, size: size)
    }

    static func echoMono(_ size: CGFloat, medium: Bool = false) -> Font {
        .custom(medium ? "JetBrainsMono-Medium" : "JetBrainsMono-Regular", size: size)
    }

    /// Hero/display text — Inter SemiBold, pair with slight negative tracking.
    static func echoDisplay(_ size: CGFloat) -> Font {
        .custom("Inter-SemiBold", size: size)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// The standard surface: rounded card with a hairline stroke.
struct EchoCardModifier: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.echoCard))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.echoHairline))
    }
}

extension View {
    func echoCard(padding: CGFloat = 16) -> some View {
        modifier(EchoCardModifier(padding: padding))
    }
}

/// A hotkey drawn as a physical keycap, never as plain text.
struct KeycapView: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.echo(12, .semibold))
            .foregroundStyle(Color.echoText)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.echoCardHover)
                    .shadow(color: .black.opacity(0.3), radius: 0, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.echoHairline))
    }
}

/// Small eyebrow label above card content.
struct EyebrowText: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.echo(10, .semibold))
            .tracking(1.1)
            .foregroundStyle(Color.echoSecondary)
    }
}
