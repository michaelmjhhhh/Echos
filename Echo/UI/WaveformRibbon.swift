import SwiftUI

/// Echo's signature: a waveform with a bell-shaped envelope (tallest at the
/// center, like the app icon) that breathes gently at idle and dances with the
/// live microphone level while recording. The only element in the app allowed
/// to glow.
struct WaveformRibbon: View {
    var level: Float
    var isLive: Bool

    private static let barCount = 28
    /// Bell envelope: how tall each bar is allowed to be, 0...1 by position.
    private static let envelope: [CGFloat] = (0..<barCount).map { index in
        let x = (CGFloat(index) - CGFloat(barCount - 1) / 2) / (CGFloat(barCount) / 2)
        return 0.18 + 0.82 * exp(-2.2 * x * x)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var history: [Float] = Array(repeating: 0, count: WaveformRibbon.barCount)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: reduceMotion && !isLive)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 5) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    bar(at: index, time: time)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 88)
        .onChange(of: level) { _, newLevel in
            history.removeFirst()
            history.append(min(1, max(0, newLevel)))
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.1), value: history)
    }

    @ViewBuilder
    private func bar(at index: Int, time: TimeInterval) -> some View {
        let envelope = Self.envelope[index]
        let breathing = reduceMotion ? 0.55 : 0.4 + 0.25 * sin(time * 1.3 + Double(index) * 0.5)
        let fraction = isLive
            ? max(CGFloat(history[index]), CGFloat(breathing) * 0.25)
            : CGFloat(breathing)
        let height = 6 + envelope * fraction * 72

        Capsule()
            .fill(isLive ? Color.echoAccent : Color.echoSecondary.opacity(0.35))
            .frame(width: 4, height: height)
    }
}
