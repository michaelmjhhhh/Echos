import Foundation

/// Coalesces high-frequency recorder levels before scheduling display work on
/// the main actor. Lock-protected submission is safe from the audio callback.
final class WaveformLevelCoalescer: @unchecked Sendable {
    typealias Sleep = @Sendable () async -> Void
    typealias Delivery = @MainActor @Sendable (Float) -> Void

    private let sleep: Sleep
    private let beforeMainActorDelivery: Sleep
    private let deliver: Delivery
    private let lock = NSLock()
    private var generation = 0
    private var latest: Float?
    private var deliveryScheduled = false
    private var active = false

    init(
        interval: Duration = .milliseconds(33),
        sleep: Sleep? = nil,
        beforeMainActorDelivery: @escaping Sleep = {},
        deliver: @escaping Delivery
    ) {
        self.sleep = sleep ?? { try? await Task.sleep(for: interval) }
        self.beforeMainActorDelivery = beforeMainActorDelivery
        self.deliver = deliver
    }

    func start() {
        lock.lock()
        generation += 1
        active = true
        latest = nil
        deliveryScheduled = false
        lock.unlock()
    }

    func submit(_ level: Float) {
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        latest = level
        guard !deliveryScheduled else {
            lock.unlock()
            return
        }
        deliveryScheduled = true
        let scheduledGeneration = generation
        lock.unlock()

        Task { [weak self, sleep] in
            await sleep()
            await self?.flush(generation: scheduledGeneration)
        }
    }

    func stop() {
        lock.lock()
        generation += 1
        active = false
        latest = nil
        deliveryScheduled = false
        lock.unlock()
    }

    private func flush(generation scheduledGeneration: Int) async {
        await beforeMainActorDelivery()
        await MainActor.run {
            lock.lock()
            guard active, generation == scheduledGeneration, let level = latest else {
                lock.unlock()
                return
            }
            latest = nil
            deliveryScheduled = false
            deliver(level)
            lock.unlock()
        }
    }
}
