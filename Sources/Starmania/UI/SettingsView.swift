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
                Text("Auto tries LRCLIB (which has timed lyrics) first, then the other sources.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Lyrica server URL", text: $settings.settings.lyricaBaseURL, prompt: Text("Optional, e.g. http://localhost:9999"))

                Toggle("Show synced (highlighted) lyrics when timing is available", isOn: $settings.settings.preferSyncedLyrics)
                Toggle("Keep the timing when writing lyrics to a file", isOn: $settings.settings.storeSyncedLyrics)
                Picker("Add timing to plain lyrics", selection: $settings.settings.syncedLyricsUpgrade) {
                    modeOptions
                }
                Text("Looks for a timed version of the playing song's lyrics. Only used when at least 75% of the words are the same, so only the timing is added.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Album star") {
                Picker("Star albums automatically", selection: $settings.settings.albumStarMode) {
                    modeOptions
                }
                Picker("Count", selection: $settings.settings.albumStarCriterion) {
                    ForEach(AlbumStarCriterion.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(settings.settings.albumStarMode == .off)
                Stepper("Songs needed: \(settings.settings.albumStarThreshold)",
                        value: $settings.settings.albumStarThreshold, in: 1...50)
                    .disabled(settings.settings.albumStarMode == .off)
                if settings.settings.albumStarCriterion != .favorited {
                    Stepper("Highly rated means: \(settings.settings.albumStarMinRating)★ or more",
                            value: $settings.settings.albumStarMinRating, in: 1...5)
                        .disabled(settings.settings.albumStarMode == .off)
                }
                Text("Checked for the album that's playing. Starmania only ever adds the album star, never removes it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Year and genre") {
                Picker("Check year", selection: $settings.settings.yearCheck) { modeOptions }
                Picker("Check genre", selection: $settings.settings.genreCheck) { modeOptions }
                Text("Compares the playing album with MusicBrainz, an open music database: the year of the first release, and the genres its users voted for. Changes apply to every song of the album; for local files Music also writes them into the file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shortcuts") {
                Toggle("Global rating shortcuts", isOn: $settings.settings.ratingHotkeysEnabled)
                Text("⌃⌥1–5 rate · ⌃⌥0 clear rating · ⌃⌥F favorite · ⌃⌥D dislike")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Text("Propose: the menu bar star pulses and the panel shows the suggestion. Automate: applied right away. Checks only run for what's playing, never across the whole library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            Section {
                DisclosureGroup("Advanced") {
                    SecureField("Genius API key", text: $settings.settings.geniusAPIKey, prompt: Text("Client Access Token"))
                    Text("Genius is the last lyrics source tried. A key is included; add your own if it stops working.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("Get a Genius API key…", destination: URL(string: "https://genius.com/api-clients")!)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 680)
    }

    @ViewBuilder
    private var modeOptions: some View {
        ForEach(CheckMode.allCases, id: \.self) { Text($0.title).tag($0) }
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
