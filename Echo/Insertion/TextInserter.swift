import AppKit
import Carbon.HIToolbox

enum InsertionResult: Equatable {
    case pasted
    /// Pasting was blocked (secure input is active, e.g. a password field has
    /// focus), so the transcript was left on the clipboard for a manual paste.
    case copiedToClipboard
}

protocol TextInserting {
    @discardableResult
    func insert(_ text: String) -> InsertionResult
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
