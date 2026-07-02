import AppKit

enum Hotkey: String, CaseIterable, Identifiable {
    case rightOption
    case rightCommand
    case fn

    var id: String { rawValue }

    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .fn: return 63
        }
    }

    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption: return .option
        case .rightCommand: return .command
        case .fn: return .function
        }
    }

    var label: String {
        switch self {
        case .rightOption: return "Right ⌥"
        case .rightCommand: return "Right ⌘"
        case .fn: return "Fn 🌐"
        }
    }

    var caveat: String? {
        switch self {
        case .fn:
            return "Set System Settings → Keyboard → “Press 🌐 key” to “Do Nothing” first, or macOS will also trigger its own dictation/emoji picker."
        default:
            return nil
        }
    }
}
