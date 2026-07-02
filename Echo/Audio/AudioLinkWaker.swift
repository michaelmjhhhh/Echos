import AVFoundation

/// Wakes a dormant Bluetooth audio link by playing a short burst of silence
/// through the default output device. An idle AirPods link can stall forever
/// when only the microphone side is requested; any outbound audio forces the
/// link (and iPhone auto-switch handoff) to come up, after which the mic
/// engages within a second or two.
@MainActor
final class AudioLinkWaker {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    func wake() {
        guard engine == nil else { return }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)

        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let frameCount = AVAudioFrameCount(format.sampleRate * 0.4)
        guard format.sampleRate > 0,
              let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        silence.frameLength = frameCount

        do {
            try engine.start()
        } catch {
            return
        }
        self.engine = engine
        self.player = player

        player.scheduleBuffer(silence) { [weak self] in
            Task { @MainActor in self?.teardown() }
        }
        player.play()
    }

    private func teardown() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }
}
