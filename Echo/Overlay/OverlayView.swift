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
/// visual feedback that replaces the start/stop sounds.
struct OverlayView: View {
    /// The pill is always dark regardless of app appearance, so it uses the
    /// fixed dark-mode accent rather than the adaptive token.
    static let cyan = Color(nsColor: NSColor(hex: 0x00BFCF))

    @ObservedObject var model: OverlayModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.state {
            case .recording:
                if model.micReady {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(OverlayView.cyan)
                    LevelWaveform(level: model.level)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .colorScheme(.dark)
                    Text("Starting mic…")
                }
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(.dark)
                Text("Transcribing…")
            case .copyReady(let transcript):
                if model.copyConfirmed {
                    Image(systemName: "checkmark")
                        .foregroundStyle(OverlayView.cyan)
                    Text("Copied")
                } else {
                    Text(transcript)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 170, alignment: .leading)
                        .foregroundStyle(.white.opacity(0.85))
                    Button {
                        model.onCopy?()
                    } label: {
                        Text("Copy")
                            .font(.echo(12, .semibold))
                            .foregroundStyle(Color(nsColor: NSColor(hex: 0x1C1C1E)))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(OverlayView.cyan))
                    }
                    .buttonStyle(.plain)
                }
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .lineLimit(1)
            default:
                EmptyView()
            }
        }
        .tint(OverlayView.cyan)
        .font(.echo(13, .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(height: 38)
        .background(Capsule().fill(Color.black.opacity(0.88)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        .frame(width: OverlayController.panelSize.width, height: OverlayController.panelSize.height)
    }
}

/// A small scrolling bar waveform driven by the live microphone level.
private struct LevelWaveform: View {
    var level: Float
    @State private var history: [Float] = Array(repeating: 0, count: 16)

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(history.indices, id: \.self) { index in
                Capsule()
                    .fill(OverlayView.cyan.opacity(0.9))
                    .frame(width: 2.5, height: 3 + CGFloat(history[index]) * 15)
            }
        }
        .animation(.linear(duration: 0.08), value: history)
        .onChange(of: level) { _, newLevel in
            history.removeFirst()
            history.append(min(1, max(0, newLevel)))
        }
    }
}
