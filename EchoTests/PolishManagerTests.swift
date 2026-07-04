import XCTest
@testable import Echo

@MainActor
final class PolishManagerTests: XCTestCase {
    private func makeSettings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "EchoTests-\(UUID().uuidString)")!)
    }

    func testStartsOffByDefault() {
        let manager = PolishManager(settings: makeSettings(), service: MockPolishService())
        XCTAssertEqual(manager.status, .off)
        XCTAssertNil(manager.activePolisher)
    }

    func testEnablingPreparesAndBecomesReady() async {
        let settings = makeSettings()
        let service = MockPolishService()
        let manager = PolishManager(settings: settings, service: service)
        settings.polishEnabled = true
        await manager.prepareTask?.value
        XCTAssertEqual(manager.status, .ready)
        XCTAssertNotNil(manager.activePolisher)
        XCTAssertEqual(service.preparedCount, 1)
    }

    func testAlreadyEnabledAtLaunchPreparesImmediately() async {
        let settings = makeSettings()
        settings.polishEnabled = true
        let manager = PolishManager(settings: settings, service: MockPolishService())
        await manager.prepareTask?.value
        XCTAssertEqual(manager.status, .ready)
    }

    func testDisablingUnloadsAndTurnsOff() async {
        let settings = makeSettings()
        let service = MockPolishService()
        let manager = PolishManager(settings: settings, service: service)
        settings.polishEnabled = true
        await manager.prepareTask?.value
        settings.polishEnabled = false
        XCTAssertEqual(manager.status, .off)
        XCTAssertTrue(service.unloadCalled)
        XCTAssertNil(manager.activePolisher)
    }

    func testPrepareFailureRevertsToggleAndReportsError() async {
        let settings = makeSettings()
        let service = MockPolishService()
        service.prepareError = URLError(.notConnectedToInternet)
        let manager = PolishManager(settings: settings, service: service)
        settings.polishEnabled = true
        await manager.prepareTask?.value
        guard case .failed = manager.status else {
            return XCTFail("Expected failed status, got \(manager.status)")
        }
        XCTAssertFalse(settings.polishEnabled)
        XCTAssertNil(manager.activePolisher)
    }
}

// MARK: - Mock

private final class MockPolishService: Polishing {
    var prepareError: Error?
    var preparedCount = 0
    var unloadCalled = false

    func prepare(progress: @escaping (Double) -> Void) async throws {
        preparedCount += 1
        if let prepareError { throw prepareError }
        progress(1)
    }

    func unload() { unloadCalled = true }

    func polish(_ text: String) async throws -> String { text }
}
