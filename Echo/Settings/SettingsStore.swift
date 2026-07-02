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
    @Published var playSounds: Bool {
        didSet { defaults.set(playSounds, forKey: Keys.playSounds) }
    }
    @Published var modelVariant: String {
        didSet { defaults.set(modelVariant, forKey: Keys.modelVariant) }
    }
    /// Core Audio device UID of the chosen microphone; nil = system default.
    @Published var inputDeviceUID: String? {
        didSet { defaults.set(inputDeviceUID, forKey: Keys.inputDeviceUID) }
    }
    @Published var launchAtLogin: Bool {
        didSet { updateLaunchAtLogin() }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let hotkey = "hotkey"
        static let playSounds = "playSounds"
        static let modelVariant = "modelVariant"
        static let inputDeviceUID = "inputDeviceUID"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hotkey = defaults.string(forKey: Keys.hotkey).flatMap(Hotkey.init(rawValue:)) ?? .rightOption
        // The floating overlay is the primary feedback; sounds are opt-in.
        self.playSounds = defaults.object(forKey: Keys.playSounds) as? Bool ?? false
        self.modelVariant = defaults.string(forKey: Keys.modelVariant) ?? Self.defaultModelVariant
        self.inputDeviceUID = defaults.string(forKey: Keys.inputDeviceUID)
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
