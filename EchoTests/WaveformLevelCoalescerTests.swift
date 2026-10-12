import XCTest
@testable import Echo

@MainActor
final class WaveformLevelCoalescerTests: XCTestCase {
    func testBurstDeliversOnlyLatestLevel() async {
        let sleeper = ControlledSleeper()
        var delivered: [Float] = []
        let sut = WaveformLevelCoalescer(
            sleep: { await sleeper.sleep() },
            deliver: { delivered.append($0) }
        )

        sut.start()
        sut.submit(0.1)
        sut.submit(0.4)
        sut.submit(0.9)
        await sleeper.waitUntilSleeping()
        await sleeper.advance()
        await waitForDelivery { !delivered.isEmpty }

        XCTAssertEqual(delivered, [0.9])
    }

    func testStopRejectsPendingDelivery() async {
        let sleeper = ControlledSleeper()
        var delivered: [Float] = []
        let sut = WaveformLevelCoalescer(
            sleep: { await sleeper.sleep() },
            deliver: { delivered.append($0) }
        )

        sut.start()
        sut.submit(0.8)
        await sleeper.waitUntilSleeping()
        sut.stop()
        await sleeper.advance()
        await waitForDelivery(timeout: .milliseconds(100)) { !delivered.isEmpty }

        XCTAssertTrue(delivered.isEmpty)
    }

    func testRestartDoesNotDeliverPreviousGeneration() async {
        let sleeper = ControlledSleeper()
        var delivered: [Float] = []
        let sut = WaveformLevelCoalescer(
            sleep: { await sleeper.sleep() },
            deliver: { delivered.append($0) }
        )

        sut.start()
        sut.submit(0.8)
        await sleeper.waitUntilSleeping()
        sut.stop()
        sut.start()
        await sleeper.advance()
        await waitForDelivery(timeout: .milliseconds(100)) { !delivered.isEmpty }

        XCTAssertTrue(delivered.isEmpty)
    }

    func testStopWhileDeliveryIsQueuedOnMainActorRejectsStaleLevel() async {
        let sleeper = ControlledSleeper()
        let deliveryGate = ControlledSleeper()
        var delivered: [Float] = []
        let sut = WaveformLevelCoalescer(
            sleep: { await sleeper.sleep() },
            beforeMainActorDelivery: { await deliveryGate.sleep() },
            deliver: { delivered.append($0) }
        )

        sut.start()
        sut.submit(0.8)
        await sleeper.waitUntilSleeping()
        await sleeper.advance()
        await deliveryGate.waitUntilSleeping()

        sut.stop()
        await deliveryGate.advance()
        await waitForDelivery(timeout: .milliseconds(100)) { !delivered.isEmpty }

        XCTAssertTrue(delivered.isEmpty)
    }
}

/// Delivery hops from the sleeping task to the main actor, so one `Task.yield()`
/// does not guarantee it has run. Returns once `delivered()` is true or the
/// timeout passes; tests expecting no delivery wait out the full window.
@MainActor
private func waitForDelivery(timeout: Duration = .seconds(1), until delivered: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !delivered(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(1))
    }
}

private actor ControlledSleeper {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func sleep() async {
        await withCheckedContinuation { continuations.append($0) }
    }

    func waitUntilSleeping() async {
        while continuations.isEmpty {
            await Task.yield()
        }
    }

    func advance() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}
