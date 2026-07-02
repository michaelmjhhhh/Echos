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
    var hotkey: Hotkey = .rightOption
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false

    func start() {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        // Local monitor so the hotkey also works while Echo itself has focus.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        isDown = false
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == hotkey.keyCode else { return }
        let pressed = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .contains(hotkey.modifierFlag)
        guard pressed != isDown else { return }
        isDown = pressed
        pressed ? onKeyDown?() : onKeyUp?()
    }
}
