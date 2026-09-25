import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
    case home
    case insights
    case history
    case dictionary
    case snippets
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .insights: return "Insights"
        case .history: return "History"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "waveform"
        case .insights: return "chart.bar.xaxis"
        case .history: return "clock.arrow.circlepath"
        case .dictionary: return "character.book.closed"
        case .snippets: return "text.insert"
        case .settings: return "gearshape"
        }
    }

    /// ⌘1…⌘6, in sidebar order.
    var shortcutKey: KeyEquivalent {
        switch self {
        case .home: return "1"
        case .insights: return "2"
        case .history: return "3"
        case .dictionary: return "4"
        case .snippets: return "5"
        case .settings: return "6"
        }
    }

    var shortcutHint: String {
        switch self {
        case .home: return "⌘1"
        case .insights: return "⌘2"
        case .history: return "⌘3"
        case .dictionary: return "⌘4"
        case .snippets: return "⌘5"
        case .settings: return "⌘6"
        }
    }
}

struct MainWindowView: View {
    @EnvironmentObject private var controller: DictationController
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var transcripts: TranscriptStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @State private var section: MainSection = .home
    @State private var microphoneName = "System Default"

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: EchoLayout.sidebarWidth)
                .background(.ultraThinMaterial)

            Rectangle()
                .fill(Color.echoHairline)
                .frame(width: 1)

            Group {
                switch section {
                case .home: HomeView(section: $section)
                case .insights: InsightsView()
                case .history: HistoryView()
                case .dictionary: DictionaryView()
                case .snippets: SnippetsView()
                case .settings: SettingsView()
                }
            }
            .id(section)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: 6)).animation(Motion.spring),
                removal: .opacity.animation(Motion.exit)
            ))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.echoBase)
        .background(sectionShortcuts)
        .tint(Color.echoAccent)
        .frame(minWidth: 720, minHeight: 560)
        .onAppear {
            controller.openMainWindow = {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        // Resolve the mic name only when the selection changes — never in a
        // body computed property. Core Audio HAL queries are synchronous and
        // block the main thread (and with it the whole UI) whenever coreaudiod
        // stalls, so they must not run on every render.
        .onChange(of: settings.inputDeviceUID, initial: true) { _, uid in
            Task { microphoneName = await Task.detached(priority: .utility) { Self.resolveMicrophoneName(uid: uid) }.value }
        }
        .onReceive(NotificationCenter.default.publisher(for: AudioInputDevices.changedNotification)) { _ in
            let uid = settings.inputDeviceUID
            Task { microphoneName = await Task.detached(priority: .utility) { Self.resolveMicrophoneName(uid: uid) }.value }
        }
    }

    nonisolated static func resolveMicrophoneName(uid: String?) -> String {
        guard let uid else { return "System Default" }
        return AudioInputDevices.all().first { $0.uid == uid }?.name ?? "System Default"
    }

    /// Hidden ⌘1…⌘6 buttons — keyboard-first navigation without visible chrome.
    private var sectionShortcuts: some View {
        ForEach(MainSection.allCases) { item in
            Button(item.title) {
                withAnimation(reduceMotion ? nil : Motion.spring) { section = item }
            }
            .keyboardShortcut(item.shortcutKey, modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "waveform")
                    .font(.system(size: IconSize.title, weight: .semibold))
                    .foregroundStyle(Color.echoAccent)
                    .accessibilityHidden(true)
                Text("Echo")
                    .font(.echoDisplay(16))
                    .tracking(-0.2)
                    .foregroundStyle(Color.echoText)
            }
            .padding(.horizontal, Spacing.s)
            .padding(.top, 20)
            .padding(.bottom, Spacing.m)

            ForEach(MainSection.allCases) { item in
                SidebarRow(section: item, isSelected: section == item) {
                    withAnimation(reduceMotion ? nil : Motion.spring) { section = item }
                }
            }

            Spacer()

            sidebarFooter
        }
        .padding(.horizontal, 10)
        .padding(.bottom, Spacing.s)
    }

    /// Always-visible health readout — answers "is Echo even running?" from any screen.
    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(shortStatus)
                    .font(.echo(11, .medium))
                    .foregroundStyle(Color.echoText)
                    .lineLimit(1)
            }
            HStack(spacing: 7) {
                Image(systemName: "mic")
                    .font(.system(size: IconSize.caption))
                    .foregroundStyle(Color.echoSecondary)
                Text(controller.activeMicrophoneName ?? microphoneName)
                    .font(.echo(11))
                    .foregroundStyle(Color.echoSecondary)
                    .lineLimit(1)
            }
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.echoCard.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.echoHairline)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Echo status")
        .accessibilityValue("\(shortStatus), microphone \(controller.activeMicrophoneName ?? microphoneName)")
    }

    private var statusColor: Color {
        switch controller.state {
        case .idle, .recording, .transcribing: return .echoAccent
        case .error, .needsPermissions: return .echoWarning
        default: return .echoSecondary
        }
    }

    private var shortStatus: String {
        if controller.isCancelling { return "Cancelling" }
        switch controller.state {
        case .launching: return "Starting…"
        case .needsPermissions: return "Needs permissions"
        case .downloadingModel(let progress): return "Downloading \(Int(progress * 100))%"
        case .loadingModel: return "Loading model"
        case .idle: return "Ready"
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case .copyReady: return "Ready to copy"
        case .error: return "Attention needed"
        }
    }

}

private struct SidebarRow: View {
    let section: MainSection
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Capsule()
                    .fill(Color.echoAccent)
                    .frame(width: 3, height: 16)
                    .opacity(isSelected ? 1 : 0)
                Image(systemName: section.symbol)
                    .font(.system(size: IconSize.body, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.echoAccent : Color.echoSecondary)
                Text(section.title)
                    .font(.echo(13, isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.echoText : Color.echoSecondary)
                Spacer()
            }
            .padding(.leading, 7)
            .padding(.trailing, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(isSelected ? Color.echoCardHover : (isHovering ? Color.echoCard.opacity(0.6) : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(EchoPressButtonStyle())
        .help("\(section.title) (\(section.shortcutHint))")
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { hovering in
            withAnimation(Motion.ease) { isHovering = hovering }
        }
    }
}
