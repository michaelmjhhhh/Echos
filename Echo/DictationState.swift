import Foundation

enum DictationState: Equatable {
    case launching
    case needsPermissions(microphone: Bool, accessibility: Bool)
    case downloadingModel(progress: Double)
    case loadingModel
    case idle
    case recording
    case transcribing
    /// Transcription finished but there was no text cursor to paste into —
    /// the floating pill offers a Copy button instead.
    case copyReady(String)
    case error(String)

    var menuBarSymbol: String {
        switch self {
        case .launching: return "hourglass"
        case .needsPermissions: return "mic.slash"
        case .downloadingModel: return "arrow.down.circle"
        case .loadingModel: return "hourglass"
        case .idle: return "mic"
        case .recording: return "waveform"
        case .transcribing: return "ellipsis.circle"
        case .copyReady: return "doc.on.clipboard"
        case .error: return "exclamationmark.triangle"
        }
    }

    @MainActor
    var statusDescription: String {
        switch self {
        case .launching: return "Starting up…"
        case .needsPermissions(let mic, let ax):
            var missing: [String] = []
            if !mic { missing.append("Microphone") }
            if !ax { missing.append("Accessibility") }
            return "Needs permission: \(missing.joined(separator: ", "))"
        case .downloadingModel(let progress):
            return "Downloading model… \(Int(progress * 100))%"
        case .loadingModel: return "Loading model…"
        case .idle: return "Ready — hold \(SettingsStore.shared.hotkey.label) to dictate"
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .copyReady: return "No text field found — click the pill to copy"
        case .error(let message): return "Error: \(message)"
        }
    }
}
