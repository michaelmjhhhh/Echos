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
/// Pure decision logic for "is there somewhere to paste?", separated from the
/// Accessibility calls so the rules are unit-testable.
///
/// Bias: a wrong paste is recoverable, a wrongly withheld one breaks the core
/// flow. Only *confident* negatives (leaf controls, Finder desktop/lists,
/// secure input) route to the copy pill. Container roles — AXWindow, AXGroup,
/// AXWebArea — are what Electron apps report for real text fields before
/// their accessibility tree is enabled, so they must paste.
enum InsertionTargetHeuristic {
    static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"
    ]
    /// Leaf controls and read-only containers that can never take a paste.
    static let definitelyNotEditable: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXLink",
        "AXStaticText", "AXImage", "AXSlider", "AXMenuItem", "AXMenuButton",
        "AXDisclosureTriangle",
        "AXScrollArea", "AXList", "AXTable", "AXOutline"
    ]

    static func hasTarget(
        secureInput: Bool,
        focusedElementExists: Bool,
        role: String?,
        valueSettable: Bool,
        selectedTextRangeSettable: Bool
    ) -> Bool {
        guard !secureInput else { return false }
        // No focused element usually means the app has no AX support at all
        // (not "no cursor") — uncertainty must not withhold the paste.
        guard focusedElementExists else { return true }
        if let role, editableRoles.contains(role) { return true }
        if valueSettable || selectedTextRangeSettable { return true }
        if let role, definitelyNotEditable.contains(role) { return false }
        return true
    }
}

final class TextInserter: TextInserting {
    /// How long to wait before restoring the clipboard — long enough for the
    /// frontmost app to service the paste event.
    private let restoreDelay: TimeInterval = 0.7

    var hasInsertionTarget: Bool {
        let secureInput = IsSecureEventInputEnabled()

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )

        guard error == .success, let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return InsertionTargetHeuristic.hasTarget(
                secureInput: secureInput,
                focusedElementExists: false,
                role: nil,
                valueSettable: false,
                selectedTextRangeSettable: false
            )
        }
        let element = focusedRef as! AXUIElement

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)

        var valueSettable = DarwinBoolean(false)
        _ = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)
        var rangeSettable = DarwinBoolean(false)
        _ = AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &rangeSettable)

        return InsertionTargetHeuristic.hasTarget(
            secureInput: secureInput,
            focusedElementExists: true,
            role: roleRef as? String,
            valueSettable: valueSettable.boolValue,
            selectedTextRangeSettable: rangeSettable.boolValue
        )
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
