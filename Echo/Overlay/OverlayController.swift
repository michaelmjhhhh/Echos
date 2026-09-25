import AppKit
import SwiftUI

/// Owns the floating, non-activating panel that shows dictation state near the
/// bottom of the screen. Joins all Spaces,
/// and never steals focus from the app being dictated into.
@MainActor
final class OverlayController {
    static let panelSize = NSSize(width: EchoLayout.overlaySize.width, height: EchoLayout.overlaySize.height)

    private let model = OverlayModel()
    private lazy var panel: NSPanel = makePanel()
    private var isVisible = false

    /// Invoked when the user clicks Copy on the pill.
    var onCopy: (() -> Void)? {
        get { model.onCopy }
        set { model.onCopy = newValue }
    }

    var onCancel: (() -> Void)? {
        get { model.onCancel }
        set { model.onCancel = newValue }
    }

    var onOpen: (() -> Void)? {
        get { model.onOpen }
        set { model.onOpen = newValue }
    }

    func update(state: DictationState, level: Float, micReady: Bool, copyConfirmed: Bool) {
        model.level = level
        model.micReady = micReady
        let confirmationChanged = model.copyConfirmed != copyConfirmed
        model.copyConfirmed = copyConfirmed
        guard state != model.state || confirmationChanged else { return }
        model.state = state

        panel.ignoresMouseEvents = false

        switch state {
        case .recording, .transcribing, .copyReady, .error:
            show()
        case .idle where copyConfirmed:
            show()
        default:
            hide()
        }
    }

    func updateCancellation(_ cancelling: Bool) { model.isCancelling = cancelling }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .utilityWindow
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
        return panel
    }

    /// Honors the system Reduce Motion setting — fades become instant.
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func show() {
        position()
        guard !isVisible else { return }
        isVisible = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : Motion.overlayFadeIn
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard isVisible else { return }
        isVisible = false
        NSAnimationContext.runAnimationGroup({ [reduceMotion] context in
            context.duration = reduceMotion ? 0 : Motion.overlayFadeOut
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isVisible else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    private func position() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - Self.panelSize.width / 2,
            y: visible.minY + 24
        ))
    }
}
