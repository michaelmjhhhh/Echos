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
        await Task.yield()

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
        await Task.yield()

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
        await Task.yield()

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
        await Task.yield()

        XCTAssertTrue(delivered.isEmpty)
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
