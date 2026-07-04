import Combine
import Foundation

/// Owns the polish model's lifecycle, driven by the Settings toggle:
/// enabling downloads/loads the model with progress, disabling unloads it.
/// Publishes status for SettingsView and hands DictationController a ready
/// polisher — dictation never waits on a download.
@MainActor
final class PolishManager: ObservableObject {
    enum Status: Equatable {
        case off
        case preparing(progress: Double)
        case ready
        case failed(String)
    }

    @Published private(set) var status: Status = .off

    private let settings: SettingsStore
    private let service: Polishing
    private var cancellables: Set<AnyCancellable> = []

    /// Exposed so tests can await the in-flight preparation.
    private(set) var prepareTask: Task<Void, Never>?

    init(settings: SettingsStore = .shared, service: Polishing = PolishService()) {
        self.settings = settings
        self.service = service
        // The test host must never kick off a real model download just
        // because the developer's defaults have polish enabled (mirrors the
        // isHostingTests guard in DictationController).
        let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if isHostingTests && service is PolishService { return }
        settings.$polishEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in self?.polishEnabledChanged(enabled) }
            .store(in: &cancellables)
    }

    /// The polisher DictationController should use right now, or nil while
    /// off, still preparing, or failed.
    var activePolisher: Polishing? {
        status == .ready ? service : nil
    }

    private func polishEnabledChanged(_ enabled: Bool) {
        prepareTask?.cancel()
        prepareTask = nil
        guard enabled else {
            service.unload()
            status = .off
            return
        }
        status = .preparing(progress: 0)
        prepareTask = Task { [weak self, service] in
            do {
                try await service.prepare { fraction in
                    Task { @MainActor in
                        guard let self, case .preparing = self.status else { return }
                        self.status = .preparing(progress: fraction)
                    }
                }
                guard !Task.isCancelled else { return }
                self?.status = .ready
            } catch {
                guard !Task.isCancelled else { return }
                // Revert the toggle so Settings reflects reality (its sink
                // sets status to .off), then surface the error on top.
                self?.settings.polishEnabled = false
                self?.status = .failed(error.localizedDescription)
            }
        }
    }
}
