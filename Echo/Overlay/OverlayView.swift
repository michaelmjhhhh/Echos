import SwiftUI

@MainActor
final class OverlayModel: ObservableObject {
    @Published var state: DictationState = .idle
    @Published var level: Float = 0
    @Published var micReady = false
    @Published var copyConfirmed = false
    var onCopy: (() -> Void)?
}

/// The floating pill shown near the bottom of the screen while dictating —
/// visual feedback that replaces the start/stop sounds. Always dark regardless
/// of app appearance, so it draws exclusively from the fixed `echoOverlay*` /
/// `*Fixed` tokens. The pill renders only its own dictation state — no other
/// warnings or notices ever appear mid-recording. Carries the app's single
/// sanctioned shadow (HUD elevation).
struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Drives the entrance spring: the pill content rises 6pt as the panel
    /// fades in, then settles.
    @State private var entered = false

    private var isVisibleState: Bool {
        switch model.state {
        case .recording, .transcribing, .copyReady, .error: return true
        default: return false
        }
    }

    var body: some View {
        HStack(spacing: Spacing.s - 2) {
            switch model.state {
            case .recording:
                if model.micReady {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(Color.echoAccentFixed)
                        .accessibilityHidden(true)
                    LevelWaveform(level: model.level)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Starting mic…")
                }
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text("Transcribing…")
            case .copyReady(let transcript):
                if model.copyConfirmed {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.echoAccentFixed)
                        .accessibilityHidden(true)
                    Text("Copied")
                } else {
                    Text(transcript)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 170, alignment: .leading)
                        .foregroundStyle(Color.echoOverlayTextDim)
                    Button("Copy") {
                        model.onCopy?()
                    }
                    .buttonStyle(EchoPrimaryButtonStyle(fixed: true))
                    .accessibilityLabel("Copy transcript")
                }
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.echoWarningFixed)
                    .accessibilityHidden(true)
                Text(message)
                    .lineLimit(1)
            default:
                EmptyView()
            }
        }
        .tint(Color.echoAccentFixed)
        .font(.echo(13, .medium))
        .foregroundStyle(Color.echoOverlayText)
        .padding(.horizontal, 18)
        .frame(height: 38)
        .background(Capsule().fill(Color.echoOverlayBackground))
        .overlay(Capsule().strokeBorder(Color.echoOverlayHairline))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        .offset(y: entered ? 0 : 6)
        .opacity(entered ? 1 : 0)
        .animation(reduceMotion ? nil : Motion.spring, value: model.state)
        .animation(reduceMotion ? nil : Motion.spring, value: model.copyConfirmed)
        .frame(width: EchoLayout.overlaySize.width, height: EchoLayout.overlaySize.height)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Echo dictation")
        .onChange(of: isVisibleState) { _, visible in
            if visible {
                if reduceMotion {
                    entered = true
                } else {
                    withAnimation(Motion.spring) { entered = true }
                }
            } else {
                entered = false
            }
        }
    }
}

/// A small scrolling bar waveform driven by the live microphone level.
/// Decorative — hidden from assistive tech; the pill's text narrates state.
private struct LevelWaveform: View {
    var level: Float
    @State private var history: [Float] = Array(repeating: 0, count: 16)

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(history.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.echoAccentFixed.opacity(0.9))
                    .frame(width: 2.5, height: 3 + CGFloat(history[index]) * 15)
            }
        }
        .animation(Motion.waveform, value: history)
        .accessibilityHidden(true)
        .onChange(of: level) { _, newLevel in
            history.removeFirst()
            history.append(min(1, max(0, newLevel)))
        }
    }
}
