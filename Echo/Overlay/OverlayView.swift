import SwiftUI

@MainActor
final class OverlayModel: ObservableObject {
    @Published var state: DictationState = .idle
    @Published var level: Float = 0
}

/// The floating pill shown near the bottom of the screen while dictating —
/// visual feedback that replaces the start/stop sounds.
struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.state {
            case .recording:
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                LevelWaveform(level: model.level)
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(.dark)
                Text("Transcribing…")
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .lineLimit(1)
            default:
                EmptyView()
            }
        }
        .font(.system(size: 13, weight: .medium))
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
                    .fill(.white.opacity(0.9))
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
