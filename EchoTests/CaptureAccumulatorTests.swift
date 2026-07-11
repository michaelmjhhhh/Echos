import XCTest
@testable import Echo

final class CaptureAccumulatorTests: XCTestCase {
    func testAppendRegisteredBeforeStopIsIncluded() async throws {
        let accumulator = CaptureAccumulator(configuration: .default)
        let generation = accumulator.start()
        let token = try XCTUnwrap(accumulator.beginAppend())
        let values: [Float] = [0.1, 0.2, 0.3]

        let completion = Task {
            try? await Task.sleep(for: .milliseconds(20))
            return values.withUnsafeBufferPointer {
                accumulator.completeAppend(token, samples: $0, rms: 0.2, conversionFailed: false)
            }
        }
        let captured = await accumulator.stop()

        let completionResult = await completion.value
        XCTAssertTrue(completionResult.accepted)
        XCTAssertEqual(captured.generation, generation)
        XCTAssertEqual(captured.samples, values)
        XCTAssertFalse(captured.finalizationTimedOut)
    }

    func testAppendCannotRegisterAfterStopBegins() async throws {
        let accumulator = CaptureAccumulator(configuration: .default)
        accumulator.start()
        let existing = try XCTUnwrap(accumulator.beginAppend())
        let empty: [Float] = []

        let observer = Task {
            try? await Task.sleep(for: .milliseconds(20))
            let lateToken = accumulator.beginAppend()
            empty.withUnsafeBufferPointer {
                _ = accumulator.completeAppend(existing, samples: $0, rms: 0, conversionFailed: false)
            }
            return lateToken
        }
        _ = await accumulator.stop()

        let lateToken = await observer.value
        XCTAssertNil(lateToken)
    }

    func testConversionFailureIsCounted() async throws {
        let accumulator = CaptureAccumulator(configuration: .default)
        accumulator.start()
        let token = try XCTUnwrap(accumulator.beginAppend())
        let empty: [Float] = []
        empty.withUnsafeBufferPointer {
            _ = accumulator.completeAppend(token, samples: $0, rms: 0, conversionFailed: true)
        }

        let captured = await accumulator.stop()

        XCTAssertEqual(captured.droppedBufferCount, 1)
        XCTAssertEqual(captured.convertedBufferCount, 0)
        XCTAssertTrue(captured.samples.isEmpty)
    }

    func testFinalizationTimeoutRejectsLateCompletion() async throws {
        let accumulator = CaptureAccumulator(configuration: .default)
        accumulator.start()
        let token = try XCTUnwrap(accumulator.beginAppend())
        let started = Date()

        let captured = await accumulator.stop()

        XCTAssertTrue(captured.finalizationTimedOut)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.20)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.70)
        let late: [Float] = [0.9]
        let result = late.withUnsafeBufferPointer {
            accumulator.completeAppend(token, samples: $0, rms: 0.9, conversionFailed: false)
        }
        XCTAssertFalse(result.accepted)
    }

    func testTimedOutOldGenerationCannotContaminateNewGeneration() async throws {
        let accumulator = CaptureAccumulator(configuration: .default)
        accumulator.start()
        let oldToken = try XCTUnwrap(accumulator.beginAppend())
        _ = await accumulator.stop()

        let secondGeneration = accumulator.start()
        let newToken = try XCTUnwrap(accumulator.beginAppend())
        let old: [Float] = [0.9]
        let new: [Float] = [0.2]
        old.withUnsafeBufferPointer {
            _ = accumulator.completeAppend(oldToken, samples: $0, rms: 0.9, conversionFailed: false)
        }
        new.withUnsafeBufferPointer {
            _ = accumulator.completeAppend(newToken, samples: $0, rms: 0.2, conversionFailed: false)
        }

        let captured = await accumulator.stop()

        XCTAssertEqual(captured.generation, secondGeneration)
        XCTAssertEqual(captured.samples, new)
    }

    func testSecondStartWhileCapturingIsRejectedWithoutResettingSamples() async throws {
        let accumulator = CaptureAccumulator(configuration: .default)
        let first = accumulator.start()
        let token = try XCTUnwrap(accumulator.beginAppend())
        XCTAssertEqual(accumulator.start(), first)
        let values: [Float] = [0.3]
        values.withUnsafeBufferPointer {
            _ = accumulator.completeAppend(token, samples: $0, rms: 0.3, conversionFailed: false)
        }
        let captured = await accumulator.stop()
        XCTAssertEqual(captured.generation, first)
        XCTAssertEqual(captured.samples, values)
    }

    func testStopWithoutActiveCaptureReturnsEmptyCapture() async {
        let accumulator = CaptureAccumulator(configuration: .default)
        let captured = await accumulator.stop()
        XCTAssertTrue(captured.samples.isEmpty)
        XCTAssertEqual(captured.generation, CaptureGeneration(rawValue: 0))
    }

    func testGenerationsIncreaseAcrossCaptures() async {
        let accumulator = CaptureAccumulator(configuration: .default)
        let first = accumulator.start()
        _ = await accumulator.stop()
        let second = accumulator.start()
        _ = await accumulator.stop()
        XCTAssertGreaterThan(second.rawValue, first.rawValue)
    }
}
