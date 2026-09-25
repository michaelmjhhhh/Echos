import AppKit
import Combine
import ServiceManagement

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    /// English-optimized Whisper variant from argmaxinc/whisperkit-coreml (~600 MB).
    nonisolated static let defaultModelVariant = "distil-whisper_distil-large-v3_594MB"

    @Published var hotkey: Hotkey {
        didSet { defaults.set(hotkey.rawValue, forKey: Keys.hotkey) }
    }
    @Published var modelVariant: String {
        didSet { defaults.set(modelVariant, forKey: Keys.modelVariant) }
    }
    /// Core Audio device UID of the chosen microphone; nil = system default.
    @Published var inputDeviceUID: String? {
        didSet { defaults.set(inputDeviceUID, forKey: Keys.inputDeviceUID) }
    }
    /// Keep a local history of dictated transcripts (never leaves the Mac).
    @Published var saveHistory: Bool {
        didSet { defaults.set(saveHistory, forKey: Keys.saveHistory) }
    }
    /// Leave the latest transcript on the clipboard after dictation.
    @Published var copyTranscriptToClipboard: Bool {
        didSet { defaults.set(copyTranscriptToClipboard, forKey: Keys.copyTranscriptToClipboard) }
    }
    @Published var transcriptionLanguage: String {
        didSet { defaults.set(transcriptionLanguage, forKey: Keys.transcriptionLanguage) }
    }
    @Published var vocabularyTokenBudget: Int {
        didSet { defaults.set(vocabularyTokenBudget, forKey: Keys.vocabularyTokenBudget) }
    }
    @Published var decodingFallbackCount: Int {
        didSet { defaults.set(decodingFallbackCount, forKey: Keys.decodingFallbackCount) }
    }
    @Published var expandSnippets: Bool {
        didSet { defaults.set(expandSnippets, forKey: Keys.expandSnippets) }
    }
    @Published var saveUsageStatistics: Bool {
        didSet { defaults.set(saveUsageStatistics, forKey: Keys.saveUsageStatistics) }
    }
    /// Zero keeps usage until explicitly cleared; independent of transcript history.
    @Published var usageRetentionDays: Int {
        didSet { defaults.set(usageRetentionDays, forKey: Keys.usageRetentionDays) }
    }
    @Published private(set) var launchAtLoginError: String?
    private var refreshingLoginStatus = false

    @Published var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }
    @Published var launchAtLogin: Bool {
        didSet { if !refreshingLoginStatus { updateLaunchAtLogin() } }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let hotkey = "hotkey"
        static let modelVariant = "modelVariant"
        static let inputDeviceUID = "inputDeviceUID"
        static let saveHistory = "saveHistory"
        static let copyTranscriptToClipboard = "copyTranscriptToClipboard"
        static let appearance = "appearance"
        static let transcriptionLanguage = "transcriptionLanguage"
        static let vocabularyTokenBudget = "vocabularyTokenBudget"
        static let decodingFallbackCount = "decodingFallbackCount"
        static let expandSnippets = "expandSnippets"
        static let saveUsageStatistics = "saveUsageStatistics"
        static let usageRetentionDays = "usageRetentionDays"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hotkey = defaults.string(forKey: Keys.hotkey).flatMap(Hotkey.init(rawValue:)) ?? .rightOption
        self.modelVariant = defaults.string(forKey: Keys.modelVariant) ?? Self.defaultModelVariant
        let savedInput = defaults.string(forKey: Keys.inputDeviceUID)
        if let savedInput, AudioInputDevices.isTransientSelection(uid: savedInput) {
            self.inputDeviceUID = nil
            defaults.removeObject(forKey: Keys.inputDeviceUID)
        } else {
            self.inputDeviceUID = savedInput
        }
        self.saveHistory = defaults.object(forKey: Keys.saveHistory) as? Bool ?? true
        self.copyTranscriptToClipboard = defaults.object(forKey: Keys.copyTranscriptToClipboard) as? Bool ?? true
        self.transcriptionLanguage = defaults.string(forKey: Keys.transcriptionLanguage) ?? "en"
        self.vocabularyTokenBudget = min(200, max(0, defaults.object(forKey: Keys.vocabularyTokenBudget) as? Int ?? 200))
        self.decodingFallbackCount = min(5, max(0, defaults.object(forKey: Keys.decodingFallbackCount) as? Int ?? 5))
        self.expandSnippets = defaults.object(forKey: Keys.expandSnippets) as? Bool ?? true
        self.saveUsageStatistics = defaults.object(forKey: Keys.saveUsageStatistics) as? Bool ?? true
        self.usageRetentionDays = max(0, defaults.object(forKey: Keys.usageRetentionDays) as? Int ?? 0)
        self.appearance = defaults.string(forKey: Keys.appearance)
            .flatMap(AppAppearance.init(rawValue:)) ?? .system
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        applyAppearance()
    }

    func applyAppearance() {
        NSApp?.appearance = appearance.nsAppearance
    }

    func refreshLaunchAtLoginStatus() {
        refreshingLoginStatus = true
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshingLoginStatus = false
        if SMAppService.mainApp.status == .requiresApproval {
            launchAtLoginError = "Allow Echo in System Settings → General → Login Items."
        }
    }

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLoginStatus()
    }
}
