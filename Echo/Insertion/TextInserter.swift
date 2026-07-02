import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum InsertionResult: Equatable {
    case pasted
    /// Pasting was blocked (secure input is active, e.g. a password field has
    /// focus), so the transcript was left on the clipboard for a manual paste.
    case copiedToClipboard
}

protocol TextInserting {
    /// Whether the frontmost app currently has somewhere to paste into.
    var hasInsertionTarget: Bool { get }
    @discardableResult
    func insert(_ text: String) -> InsertionResult
    func copyToClipboard(_ text: String)
}

/// Inserts text at the cursor of the frontmost app via the clipboard:
/// save whatever is on the pasteboard, put the transcript there, synthesize
/// ⌘V, then restore the original pasteboard contents. Paste is the only
/// insertion method that behaves consistently across native, Electron, and
/// browser apps.
final class TextInserter: TextInserting {
    /// How long to wait before restoring the clipboard — long enough for the
    /// frontmost app to service the paste event.
    private let restoreDelay: TimeInterval = 0.7

    /// Roles that clearly accept typed text.
    private static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"
    ]
    /// Roles that clearly don't. Anything ambiguous (e.g. AXWebArea in
    /// Electron/browser apps, which may be contenteditable) is treated as
    /// insertable — a wrong paste is recoverable, a wrongly withheld one
    /// breaks the core flow.
    private static let nonEditableRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXLink",
        "AXStaticText", "AXImage", "AXList", "AXTable", "AXOutline",
        "AXScrollArea", "AXSplitGroup", "AXTabGroup", "AXToolbar",
        "AXMenu", "AXMenuItem", "AXWindow", "AXSlider", "AXDisclosureTriangle"
    ]

    var hasInsertionTarget: Bool {
        // Secure input (password fields) blocks synthetic ⌘V outright.
        guard !IsSecureEventInputEnabled() else { return false }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard error == .success, let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            // Nothing has keyboard focus at all — no cursor to paste at.
            return false
        }
        let element = focusedRef as! AXUIElement

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String

        if let role, Self.editableRoles.contains(role) { return true }

        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }

        if let role, Self.nonEditableRoles.contains(role) { return false }
        // Unknown role — err on the side of pasting.
        return true
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @discardableResult
    func insert(_ text: String) -> InsertionResult {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard !IsSecureEventInputEnabled() else {
            return .copiedToClipboard
        }

        synthesizeCommandV()
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            self.restore(saved, to: pasteboard)
        }
        return .pasted
    }

    private func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }

    private func synthesizeCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
