import SwiftUI

/// Echo's signature: a wide waveform that breathes gently at idle and mirrors
/// the live microphone level while recording. The floating pill carries the
/// small version; this is the grown-up one for the Home hero.
struct WaveformRibbon: View {
    var level: Float
    var isLive: Bool

    private static let barCount = 44

    @State private var history: [Float] = Array(repeating: 0, count: WaveformRibbon.barCount)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    let idle = 0.05 + 0.045 * sin(time * 1.4 + Double(index) * 0.42)
                    let value = isLive
                        ? max(CGFloat(history[index]), CGFloat(idle) * 0.4)
                        : CGFloat(idle)
                    Capsule()
                        .fill(isLive ? Color.echoCoral : Color.echoSecondary.opacity(0.4))
                        .frame(width: 3.5, height: 6 + value * 58)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 72)
        .onChange(of: level) { _, newLevel in
            history.removeFirst()
            history.append(min(1, max(0, newLevel)))
        }
        .animation(.linear(duration: 0.1), value: history)
    }
}
