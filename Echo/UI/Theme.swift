import SwiftUI

/// Echo's design tokens — "3D Sculpt" system: studio-grey neutrals, one
/// mesh-cyan accent that drives everything interactive/live, flat on purpose
/// (no gradients, no shadows — borders and negative space carry the design).
extension Color {
    static let echoBase = dynamic(dark: NSColor(hex: 0x1C1C1E), light: NSColor(hex: 0xF0EFED))
    static let echoCard = dynamic(dark: NSColor(hex: 0x252527), light: NSColor.white)
    static let echoCardHover = dynamic(dark: NSColor(hex: 0x2C2C2F), light: NSColor(hex: 0xE9E8E6))
    static let echoHairline = dynamic(
        dark: NSColor.white.withAlphaComponent(0.10),
        light: NSColor.black.withAlphaComponent(0.10)
    )
    static let echoText = dynamic(dark: NSColor(hex: 0xE8E8E6), light: NSColor(hex: 0x1C1C1E))
    static let echoSecondary = dynamic(dark: NSColor(hex: 0x8C8B88), light: NSColor(hex: 0x6A6965))
    /// Mesh cyan — the sole accent. Live states, active nav, interaction.
    static let echoAccent = dynamic(dark: NSColor(hex: 0x00BFCF), light: NSColor(hex: 0x00808F))
    /// Semantic warning only (permissions, errors) — never decorative.
    static let echoWarning = dynamic(dark: NSColor(hex: 0xE5A83B), light: NSColor(hex: 0x9A6A00))

    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
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

/// Type system: Space Grotesk (display), Inter (body), IBM Plex Mono (labels
/// and data). All bundled in Resources/Fonts.
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
        .custom(medium ? "IBMPlexMono-Medium" : "IBMPlexMono-Regular", size: size)
    }

    /// Display face — Space Grotesk, pair with -0.02em tracking.
    static func echoDisplay(_ size: CGFloat) -> Font {
        .custom("SpaceGrotesk-Medium", size: size)
    }
}

/// One motion system for the whole app.
enum Motion {
    static let spring = Animation.spring(duration: 0.3)
    static let ease = Animation.easeOut(duration: 0.15)
}

/// The standard surface: flat fill, hairline border, 10pt radius. No gradients
/// or shadows — this system is flat on purpose.
struct EchoCardModifier: ViewModifier {
    var padding: CGFloat = 16

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(shape.fill(Color.echoCard))
            .overlay(shape.strokeBorder(Color.echoHairline))
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
            .font(.echoMono(11, medium: true))
            .foregroundStyle(Color.echoText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.echoCardHover))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.echoHairline))
    }
}

/// Small mono eyebrow label above card content — IBM Plex Mono, wide tracking.
struct EyebrowText: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.echoMono(10, medium: true))
            .tracking(0.7)
            .foregroundStyle(Color.echoSecondary)
    }
}
