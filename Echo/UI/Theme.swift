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

    /// Foreground for content sitting on an accent fill: dark ink on the
    /// bright dark-mode cyan, white on the deeper light-mode cyan.
    static let echoOnAccent = dynamic(dark: NSColor(hex: 0x1C1C1E), light: NSColor.white)

    // MARK: Fixed HUD tokens — the overlay pill is always dark regardless of
    // app appearance, so it draws from these non-adaptive values.
    static let echoOverlayBackground = Color.black.opacity(0.88)
    static let echoOverlayHairline = Color.white.opacity(0.12)
    static let echoOverlayText = Color.white
    static let echoOverlayTextDim = Color.white.opacity(0.85)
    static let echoAccentFixed = Color(nsColor: NSColor(hex: 0x00BFCF))
    static let echoWarningFixed = Color(nsColor: NSColor(hex: 0xE5A83B))
    static let echoOnAccentFixed = Color(nsColor: NSColor(hex: 0x1C1C1E))

    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

/// 4pt spacing grid — every gap and padding in the app comes from here.
enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
}

/// SF Symbol point sizes — icons scale with the text they sit beside.
enum IconSize {
    static let caption: CGFloat = 9
    static let small: CGFloat = 12
    static let body: CGFloat = 13
    static let title: CGFloat = 15
    static let hero: CGFloat = 28
}

/// Corner radii, smallest to largest surface.
enum Radius {
    static let keycap: CGFloat = 6
    static let control: CGFloat = 8
    static let card: CGFloat = 10
}

/// Fixed structural dimensions shared across screens.
enum EchoLayout {
    static let sidebarWidth: CGFloat = 210
    static let contentMaxWidth: CGFloat = 640
    static let contentPadding: CGFloat = 24
    static let waveformHeight: CGFloat = 88
    static let settingsControlWidth: CGFloat = 220
    static let overlaySize = CGSize(width: 320, height: 56)
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

/// One motion system for the whole app. Enters use springs, exits are quicker
/// than enters, and micro-feedback lands within a frame or two of the input.
enum Motion {
    /// State and layout changes — sections, hero status, list entrances.
    static let spring = Animation.spring(duration: 0.3)
    /// Hover and other micro interactions.
    static let ease = Animation.easeOut(duration: 0.15)
    /// Press acknowledgement — must read within ~100ms of the click.
    static let press = Animation.easeOut(duration: 0.1)
    /// Removals — exits run faster than enters so the UI feels responsive.
    static let exit = Animation.easeOut(duration: 0.12)
    /// Live audio bars — linear so level changes track the signal.
    static let waveform = Animation.linear(duration: 0.1)
    /// Per-row delay for staggered list entrances.
    static let staggerStep: TimeInterval = 0.04
    /// HUD panel fades (AppKit side) — in slower than out, same as SwiftUI.
    static let overlayFadeIn: TimeInterval = 0.18
    static let overlayFadeOut: TimeInterval = 0.12
}

/// The standard surface: flat fill, hairline border, 10pt radius. No gradients
/// or shadows — this system is flat on purpose.
struct EchoCardModifier: ViewModifier {
    var padding: CGFloat = Spacing.m

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(shape.fill(Color.echoCard))
            .overlay(shape.strokeBorder(Color.echoHairline))
    }
}

extension View {
    func echoCard(padding: CGFloat = Spacing.m) -> some View {
        modifier(EchoCardModifier(padding: padding))
    }

    /// The standard content column: capped width, centered, uniform padding.
    func echoContentColumn() -> some View {
        frame(maxWidth: EchoLayout.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(EchoLayout.contentPadding)
    }

    /// Staggered list entrance: row `index` fades in with a 4pt rise, each row
    /// one `Motion.staggerStep` behind the last. Rows past the cap (and all
    /// rows under Reduce Motion) appear instantly so long lists never drag.
    func echoStagger(_ index: Int, reduceMotion: Bool) -> some View {
        modifier(EchoStaggerModifier(index: index, reduceMotion: reduceMotion))
    }

    /// Flat 2pt accent focus ring — the keyboard equivalent of hover. No glow.
    func echoFocusRing(_ isFocused: Bool, radius: CGFloat = Radius.control) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius + 2, style: .continuous)
                .strokeBorder(Color.echoAccent.opacity(isFocused ? 0.6 : 0), lineWidth: 2)
                .padding(-3)
        )
        .animation(Motion.ease, value: isFocused)
    }
}

/// Entrance stagger for list rows — see `View.echoStagger(_:reduceMotion:)`.
struct EchoStaggerModifier: ViewModifier {
    let index: Int
    let reduceMotion: Bool

    /// Rows past this index skip the animation entirely.
    private static let cap = 8

    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 4)
            .onAppear {
                guard !shown else { return }
                if reduceMotion || index > Self.cap {
                    shown = true
                } else {
                    withAnimation(Motion.spring.delay(Double(index) * Motion.staggerStep)) {
                        shown = true
                    }
                }
            }
    }
}

/// Universal press acknowledgement: a subtle scale-down within one frame.
/// Every custom (`.plain`-styled) button in the app wears this or a style
/// that embeds it.
struct EchoPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// The one accent-filled button per screen — primary CTAs only.
/// `fixed` swaps to the non-adaptive HUD palette for the overlay pill.
struct EchoPrimaryButtonStyle: ButtonStyle {
    var fixed = false

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, fixed: fixed)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let fixed: Bool
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.echo(12, .semibold))
                .foregroundStyle(fixed ? Color.echoOnAccentFixed : Color.echoOnAccent)
                .padding(.horizontal, Spacing.s)
                .padding(.vertical, Spacing.xxs)
                .background(
                    RoundedRectangle(cornerRadius: Radius.keycap, style: .continuous)
                        .fill(fixed ? Color.echoAccentFixed : Color.echoAccent)
                        .brightness(isHovering ? 0.06 : 0)
                )
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(Motion.press, value: configuration.isPressed)
                .onHover { hovering in
                    withAnimation(Motion.ease) { isHovering = hovering }
                }
        }
    }
}

/// Card-styled secondary action: flat fill, hairline border, hover lift.
/// `destructive` tints the label with the semantic warning color.
struct EchoSecondaryButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, destructive: destructive)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let destructive: Bool
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.echo(12, .medium))
                .foregroundStyle(destructive ? Color.echoWarning : Color.echoText)
                .padding(.horizontal, Spacing.s)
                .padding(.vertical, Spacing.xxs + 1)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(isHovering ? Color.echoCardHover : Color.echoCard)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(Color.echoHairline)
                )
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(Motion.press, value: configuration.isPressed)
                .onHover { hovering in
                    withAnimation(Motion.ease) { isHovering = hovering }
                }
        }
    }
}

/// Shared empty-state layout: dimmed icon, secondary-text message, optional
/// actions row. Message content is a ViewBuilder so callers can weave a
/// `KeycapView` into the sentence.
struct EchoEmptyState<Message: View, Actions: View>: View {
    var icon: String = "waveform"
    @ViewBuilder let message: Message
    @ViewBuilder let actions: Actions

    init(
        icon: String = "waveform",
        @ViewBuilder message: () -> Message,
        @ViewBuilder actions: () -> Actions
    ) {
        self.icon = icon
        self.message = message()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: icon)
                .font(.system(size: IconSize.hero))
                .foregroundStyle(Color.echoSecondary.opacity(0.6))
            message
                .font(.echo(13))
                .foregroundStyle(Color.echoSecondary)
                .multilineTextAlignment(.center)
            actions
        }
        .frame(maxWidth: .infinity)
    }
}

extension EchoEmptyState where Actions == EmptyView {
    init(icon: String = "waveform", @ViewBuilder message: () -> Message) {
        self.init(icon: icon, message: message, actions: { EmptyView() })
    }
}

/// A hotkey drawn as a physical keycap, never as plain text.
struct KeycapView: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.echoMono(11, medium: true))
            .foregroundStyle(Color.echoText)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            .background(RoundedRectangle(cornerRadius: Radius.keycap, style: .continuous).fill(Color.echoCardHover))
            .overlay(RoundedRectangle(cornerRadius: Radius.keycap, style: .continuous).strokeBorder(Color.echoHairline))
            .accessibilityLabel("\(label) key")
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
