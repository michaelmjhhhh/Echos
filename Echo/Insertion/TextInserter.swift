import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

enum InsertionResult: Equatable {
    /// The paste event was dispatched; the destination cannot universally confirm delivery.
    case pasted
    /// Pasting was blocked (secure input is active, e.g. a password field has
    /// focus), so the transcript was left on the clipboard for a manual paste.
    case copiedToClipboard
    case copyRequired
    case failed
}

struct InsertionTarget {
    let processID: pid_t
    let bundleID: String?
    let element: AXUIElement?
    let window: AXUIElement?
    let document: String?
}

@MainActor
protocol TextInserting {
    /// Whether the frontmost app currently has somewhere to paste into.
    var hasInsertionTarget: Bool { get }
    @discardableResult
    func insert(_ text: String, keepOnClipboard: Bool) -> InsertionResult
    func copyToClipboard(_ text: String)
    func copyWithResult(_ text: String) -> Bool
    func flushPendingRestoration() async
    func captureTarget() -> InsertionTarget?
    func targetMatches(_ target: InsertionTarget?) -> Bool
    func insert(_ text: String, keepOnClipboard: Bool, target: InsertionTarget?) -> InsertionResult
}

extension TextInserting {
    func flushPendingRestoration() async {}
    func copyWithResult(_ text: String) -> Bool { copyToClipboard(text); return true }
    func captureTarget() -> InsertionTarget? { nil }
    func targetMatches(_ target: InsertionTarget?) -> Bool { true }
    func insert(_ text: String, keepOnClipboard: Bool, target: InsertionTarget?) -> InsertionResult {
        guard targetMatches(target) else { return .copyRequired }
        return insert(text, keepOnClipboard: keepOnClipboard)
    }
}

/// Inserts text at the cursor of the frontmost app via the clipboard:
/// put the transcript on the pasteboard and synthesize ⌘V. When
/// `keepOnClipboard` is false, the previous pasteboard is restored after a
/// short delay. Paste is the only insertion method that behaves consistently
/// across native, Electron, and browser apps.
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

@MainActor
final class TextInserter: TextInserting {
    /// How long to wait before restoring the clipboard — long enough for the
    /// frontmost app to service the paste event.
    private let restoreDelay: TimeInterval = 0.7
    private var restoreTask: Task<Void, Never>?
    private var transactionID = UUID()
    private var ownedChangeCount: Int?
    private var originalContents: [NSPasteboardItem]?
    private let accessibilityTimeout: Float = 0.06

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, accessibilityTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        guard let value = attribute(system, kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func captureTarget() -> InsertionTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = focusedElement()
        var window: AXUIElement?
        if let element, let value = attribute(element, kAXWindowAttribute),
           CFGetTypeID(value) == AXUIElementGetTypeID() {
            window = (value as! AXUIElement)
        }
        let document = window.flatMap { attribute($0, kAXDocumentAttribute) as? String }
        return InsertionTarget(processID: app.processIdentifier, bundleID: app.bundleIdentifier,
                               element: element, window: window, document: document)
    }

    func targetMatches(_ target: InsertionTarget?) -> Bool {
        guard let target, let current = NSWorkspace.shared.frontmostApplication,
              current.processIdentifier == target.processID,
              current.bundleIdentifier == target.bundleID else { return false }
        guard let original = target.element else {
            // Some Electron applications expose no focused AX element. Preserve
            // compatibility only while the original application still has focus.
            return true
        }
        guard let focused = focusedElement(), CFEqual(original, focused) else { return false }
        if let originalWindow = target.window {
            guard let value = attribute(focused, kAXWindowAttribute),
                  CFGetTypeID(value) == AXUIElementGetTypeID(), CFEqual(originalWindow, value) else { return false }
            if let document = target.document,
               attribute(originalWindow, kAXDocumentAttribute) as? String != document { return false }
        }
        return true
    }

    var hasInsertionTarget: Bool {
        guard Permissions.accessibilityGranted, !IsSecureEventInputEnabled() else { return false }
        guard let element = focusedElement() else { return true }
        let role = attribute(element, kAXRoleAttribute) as? String
        // Password fields may expose their role even when secure event input is off.
        if role == kAXTextFieldRole,
           attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { return false }
        if let role, InsertionTargetHeuristic.editableRoles.contains(role) { return true }
        var valueSettable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)
        if valueSettable.boolValue { return true }
        var rangeSettable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &rangeSettable)
        return InsertionTargetHeuristic.hasTarget(
            secureInput: false, focusedElementExists: true, role: role,
            valueSettable: false, selectedTextRangeSettable: rangeSettable.boolValue)
    }

    func copyToClipboard(_ text: String) {
        _ = copyWithResult(text)
    }

    func copyWithResult(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = ownedChangeCount == pasteboard.changeCount
            ? (originalContents ?? snapshot(of: pasteboard)) : snapshot(of: pasteboard)
        cancelRestoration()
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restore(saved, to: pasteboard)
            return false
        }
        return true
    }

    func insert(_ text: String, keepOnClipboard: Bool, target: InsertionTarget?) -> InsertionResult {
        guard targetMatches(target) else { return .copyRequired }
        return performInsertion(text, keepOnClipboard: keepOnClipboard, target: target)
    }

    @discardableResult
    func insert(_ text: String, keepOnClipboard: Bool) -> InsertionResult {
        performInsertion(text, keepOnClipboard: keepOnClipboard, target: nil)
    }

    private func performInsertion(_ text: String, keepOnClipboard: Bool, target: InsertionTarget?) -> InsertionResult {
        // Check before touching the clipboard, including the secure-input race.
        guard Permissions.accessibilityGranted, !IsSecureEventInputEnabled() else {
            if keepOnClipboard {
                return copyWithResult(text) ? .copiedToClipboard : .failed
            }
            return .copyRequired
        }
        guard let events = commandVEvents() else { return .failed }
        let pasteboard = NSPasteboard.general
        let saved: [NSPasteboardItem]
        if ownedChangeCount == pasteboard.changeCount, let originalContents {
            saved = originalContents
        } else {
            saved = snapshot(of: pasteboard)
        }
        // Reading promised clipboard data can invoke another application. Validate
        // the destination again after that work and before changing shared state.
        if let target, !targetMatches(target) { return .copyRequired }
        guard Permissions.accessibilityGranted, !IsSecureEventInputEnabled(), hasInsertionTarget else {
            if keepOnClipboard { return copyWithResult(text) ? .copiedToClipboard : .failed }
            return .copyRequired
        }
        cancelRestoration()
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restore(saved, to: pasteboard)
            return .failed
        }
        let changeCount = pasteboard.changeCount
        let identifier = transactionID
        if let target {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID,
                  !IsSecureEventInputEnabled() else {
                if pasteboard.changeCount == changeCount { restore(saved, to: pasteboard) }
                return .copyRequired
            }
            events.0.postToPid(target.processID)
            events.1.postToPid(target.processID)
        } else {
            events.0.post(tap: .cghidEventTap)
            events.1.post(tap: .cghidEventTap)
        }
        if !keepOnClipboard {
            ownedChangeCount = changeCount
            originalContents = saved
            restoreTask = Task { [weak self, restoreDelay] in
                do { try await Task.sleep(for: .seconds(restoreDelay)) } catch { return }
                guard let self, self.transactionID == identifier else { return }
                if pasteboard.changeCount == changeCount { self.restore(saved, to: pasteboard) }
                self.ownedChangeCount = nil
                self.originalContents = nil
                self.restoreTask = nil
            }
        }
        return .pasted
    }

    private func cancelRestoration() {
        restoreTask?.cancel()
        restoreTask = nil
        transactionID = UUID()
        ownedChangeCount = nil
        originalContents = nil
    }

    func flushPendingRestoration() async {
        // Preserve the ordinary paste delay so the destination can first read
        // the text. The task still checks transaction and clipboard ownership.
        await restoreTask?.value
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
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    private func commandVEvents() -> (CGEvent, CGEvent)? {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return nil }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        return (keyDown, keyUp)
    }
}
