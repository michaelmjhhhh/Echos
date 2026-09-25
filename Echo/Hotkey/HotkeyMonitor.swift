import AppKit

@MainActor
protocol HotkeyMonitoring: AnyObject {
    var hotkey: Hotkey { get set }
    var onKeyDown: (() -> Void)? { get set }
    var onKeyUp: (() -> Void)? { get set }
    func start()
    func stop()
}

/// Watches for the dictation hotkey being held and released, system-wide.
///
/// Modifier keys only produce `flagsChanged` events, so hold/release is derived
/// from whether the hotkey's modifier flag is present when its key code fires.
/// Global monitoring requires the Accessibility permission.
@MainActor
final class HotkeyMonitor: HotkeyMonitoring {
    var hotkey: Hotkey = .rightOption {
        didSet {
            guard hotkey != oldValue else { return }
            releaseHeldKey()
        }
    }
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false
    private var reconciliationTask: Task<Void, Never>?
    private var monitorGeneration = UUID()

    func start() {
        stop()
        let generation = monitorGeneration
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                guard self?.monitorGeneration == generation else { return }
                self?.handle(event)
            }
        }
        // Local monitor so the hotkey also works while Echo itself has focus.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                guard self?.monitorGeneration == generation else { return }
                self?.handle(event)
            }
            return event
        }
        reconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self else { return }
                if self.isDown && !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(self.hotkey.keyCode)) {
                    self.releaseHeldKey()
                }
            }
        }
    }

    func stop() {
        monitorGeneration = UUID()
        reconciliationTask?.cancel()
        reconciliationTask = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        isDown = false
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == hotkey.keyCode else { return }
        // Device-dependent masks distinguish right-side modifiers. Aggregate
        // .option/.command stay set while the corresponding left key is held.
        let physicalMask: UInt
        switch hotkey {
        case .rightOption: physicalMask = 0x00000040 // NX_DEVICERALTKEYMASK
        case .rightCommand: physicalMask = 0x00000010 // NX_DEVICERCMDKEYMASK
        case .fn: physicalMask = NSEvent.ModifierFlags.function.rawValue
        }
        let pressed = event.modifierFlags.rawValue & physicalMask != 0
        guard pressed != isDown else { return }
        isDown = pressed
        pressed ? onKeyDown?() : onKeyUp?()
    }

    private func releaseHeldKey() {
        guard isDown else { return }
        isDown = false
        onKeyUp?()
    }
}
