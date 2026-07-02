import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
    case home
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "waveform"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

struct MainWindowView: View {
    @EnvironmentObject private var controller: DictationController
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var transcripts: TranscriptStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var section: MainSection = .home

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)
                .background(.ultraThinMaterial)

            Rectangle()
                .fill(Color.echoHairline)
                .frame(width: 1)

            Group {
                switch section {
                case .home: HomeView(section: $section)
                case .history: HistoryView()
                case .settings: SettingsView()
                }
            }
            .id(section)
            .transition(.opacity.combined(with: .offset(y: 6)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.echoBase)
        .frame(minWidth: 720, minHeight: 560)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.echoCoral)
                Text("Echo")
                    .font(.echoDisplay(16))
                    .tracking(-0.2)
                    .foregroundStyle(Color.echoText)
            }
            .padding(.horizontal, 12)
            .padding(.top, 20)
            .padding(.bottom, 16)

            ForEach(MainSection.allCases) { item in
                SidebarRow(section: item, isSelected: section == item) {
                    withAnimation(reduceMotion ? nil : Motion.spring) { section = item }
                }
            }

            Spacer()

            sidebarFooter
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
    }

    /// Always-visible health readout — answers "is Echo even running?" from any screen.
    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    .font(.system(size: 9))
                    .foregroundStyle(Color.echoSecondary)
                Text(microphoneName)
                    .font(.echo(11))
                    .foregroundStyle(Color.echoSecondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.echoCardTop.opacity(0.7), Color.echoCard.opacity(0.6)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.echoEdgeTop, .echoEdgeBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
    }

    private var statusColor: Color {
        switch controller.state {
        case .idle: return .green
        case .recording, .transcribing: return .echoCoral
        case .error, .needsPermissions: return .yellow
        default: return .echoSecondary
        }
    }

    private var shortStatus: String {
        switch controller.state {
        case .launching: return "Starting…"
        case .needsPermissions: return "Needs permissions"
        case .downloadingModel(let progress): return "Downloading \(Int(progress * 100))%"
        case .loadingModel: return "Loading model"
        case .idle: return "Ready"
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case .error: return "Attention needed"
        }
    }

    private var microphoneName: String {
        guard let uid = settings.inputDeviceUID else { return "System Default" }
        return AudioInputDevices.all().first { $0.uid == uid }?.name ?? "System Default"
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
                    .fill(Color.echoCoral)
                    .frame(width: 3, height: 16)
                    .opacity(isSelected ? 1 : 0)
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.echoCoral : Color.echoSecondary)
                Text(section.title)
                    .font(.echo(13, isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.echoText : Color.echoSecondary)
                Spacer()
            }
            .padding(.leading, 7)
            .padding(.trailing, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.echoCardHover : (isHovering ? Color.echoCard.opacity(0.6) : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Motion.ease) { isHovering = hovering }
        }
    }
}
