import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject private var settings = SettingsManager.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Automation") {
                Toggle("Auto-fetch lyrics when a track has none", isOn: $settings.settings.autoFetchLyrics)
                Toggle("Auto-fetch artwork when a track has none", isOn: $settings.settings.autoFetchArtwork)
                Toggle("Auto-write fetched lyrics to the file", isOn: $settings.settings.autoWriteLyrics)
                Toggle("Auto-write fetched artwork to the file if it has none", isOn: $settings.settings.autoWriteArtwork)
            }

            Section("Lyrics") {
                Picker("Preferred provider", selection: $settings.settings.lyricsProvider) {
                    ForEach(LyricsProviderOption.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                Text("The other providers are tried in turn if the preferred one finds nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Lyrica server URL", text: $settings.settings.lyricaBaseURL, prompt: Text("Optional, e.g. http://localhost:9999"))

                SecureField("Genius API key", text: $settings.settings.geniusAPIKey, prompt: Text("Client Access Token"))
                Link("Get a free Genius API key…", destination: URL(string: "https://genius.com/api-clients")!)
                    .font(.caption)
            }

            Section("Shortcuts") {
                Toggle("Global rating shortcuts", isOn: $settings.settings.ratingHotkeysEnabled)
                Text("⌃⌥1–5 rate · ⌃⌥0 clear rating · ⌃⌥F favorite · ⌃⌥D dislike")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        if service.status == .requiresApproval {
            loginError = "Approve Starmania in System Settings → General → Login Items."
            SMAppService.openSystemSettingsLoginItems()
        }
        let actual = service.status == .enabled || service.status == .requiresApproval
        if actual != launchAtLogin { launchAtLogin = actual }
    }
}
