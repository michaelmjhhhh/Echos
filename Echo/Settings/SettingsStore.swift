import Foundation
import Combine
import ServiceManagement

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    /// English-optimized Whisper variant from argmaxinc/whisperkit-coreml (~600 MB).
    static let defaultModelVariant = "distil-whisper_distil-large-v3_594MB"

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
    @Published var launchAtLogin: Bool {
        didSet { updateLaunchAtLogin() }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let hotkey = "hotkey"
        static let modelVariant = "modelVariant"
        static let inputDeviceUID = "inputDeviceUID"
        static let saveHistory = "saveHistory"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hotkey = defaults.string(forKey: Keys.hotkey).flatMap(Hotkey.init(rawValue:)) ?? .rightOption
        self.modelVariant = defaults.string(forKey: Keys.modelVariant) ?? Self.defaultModelVariant
        self.inputDeviceUID = defaults.string(forKey: Keys.inputDeviceUID)
        self.saveHistory = defaults.object(forKey: Keys.saveHistory) as? Bool ?? true
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert the toggle if the system call failed.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
