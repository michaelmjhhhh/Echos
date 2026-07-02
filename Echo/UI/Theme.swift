import SwiftUI

/// Echo's design tokens: warm graphite surfaces, hairline strokes, and one
/// coral accent reserved for "live" things (waveform, recording, status dots).
extension Color {
    static let echoBase = dynamic(dark: NSColor(hex: 0x1C1B21), light: NSColor(hex: 0xF2F1F5))
    static let echoCard = dynamic(dark: NSColor(hex: 0x26252C), light: NSColor.white)
    /// Top of the card gradient — the "light from above" model.
    static let echoCardTop = dynamic(dark: NSColor(hex: 0x2C2B33), light: NSColor.white)
    static let echoCardHover = dynamic(dark: NSColor(hex: 0x2D2C34), light: NSColor(hex: 0xEBEAEF))
    static let echoHairline = dynamic(
        dark: NSColor.white.withAlphaComponent(0.08),
        light: NSColor.black.withAlphaComponent(0.08)
    )
    /// Card edge highlights: brightest on the top edge, fading down.
    static let echoEdgeTop = dynamic(
        dark: NSColor.white.withAlphaComponent(0.14),
        light: NSColor.black.withAlphaComponent(0.10)
    )
    static let echoEdgeBottom = dynamic(
        dark: NSColor.white.withAlphaComponent(0.05),
        light: NSColor.black.withAlphaComponent(0.05)
    )
    static let echoShadow = dynamic(
        dark: NSColor.black.withAlphaComponent(0.30),
        light: NSColor.black.withAlphaComponent(0.10)
    )
    static let echoText = dynamic(dark: NSColor(hex: 0xF2F0F5), light: NSColor(hex: 0x1D1C22))
    static let echoSecondary = dynamic(dark: NSColor(hex: 0x98959F), light: NSColor(hex: 0x6E6B78))
    static let echoCoral = Color(nsColor: NSColor(hex: 0xFF5C5C))
    static let echoCoralLight = Color(nsColor: NSColor(hex: 0xFF7A6E))
    static let echoCoralDeep = Color(nsColor: NSColor(hex: 0xFF4D4D))

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

/// One motion system for the whole app.
enum Motion {
    static let spring = Animation.spring(duration: 0.3)
    static let ease = Animation.easeOut(duration: 0.15)
}

/// The standard surface. One lighting model everywhere: light falls from
/// above, so the fill is slightly brighter at the top, the edge highlight is
/// strongest on the top edge, and the card casts a soft downward shadow.
struct EchoCardModifier: ViewModifier {
    var padding: CGFloat = 16

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                shape.fill(
                    LinearGradient(
                        colors: [.echoCardTop, .echoCard],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.echoEdgeTop, .echoEdgeBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            )
            .shadow(color: .echoShadow, radius: 14, y: 6)
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
