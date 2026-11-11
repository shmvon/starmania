import Foundation

@MainActor
class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    /// Saved to disk on every change, so SwiftUI bindings and menu toggles persist immediately.
    @Published var settings: AppSettings {
        didSet {
            if settings != oldValue { save() }
        }
    }
    private let settingsURL: URL

    private init() {
        let fileManager = FileManager.default
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Starmania")

        if !fileManager.fileExists(atPath: appSupportURL.path) {
            try? fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        }

        self.settingsURL = appSupportURL.appendingPathComponent("config.json")

        if let data = try? Data(contentsOf: settingsURL),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = .default
            save()
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }

    var hasGeniusKey: Bool {
        !settings.geniusAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
