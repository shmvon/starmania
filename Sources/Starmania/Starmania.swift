import SwiftUI
import AppKit
import Combine

@main
struct StarmaniaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var panelWindow: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var clickMonitor: Any?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApplication.shared.setActivationPolicy(.accessory)
        
        // Setup menu bar item
        setupStatusItem()
        
        // Setup floating panel (no arrow, unlike NSPopover)
        setupPanel()
        
        // Start music observer
        MusicObserver.shared.startPolling()
        
        // Observe track changes to update menu bar icon
        MusicObserver.shared.$currentTrack
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)
        
    }
    
    // MARK: - Status Item
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        
        if let button = statusItem?.button {
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }
    
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        
        if event.modifierFlags.contains(.option) || event.type == .rightMouseUp {
            showSettingsMenu()
        } else {
            togglePanel()
        }
    }
    
    // MARK: - Dynamic Icon (large star with superscript/subscript)
    
    func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        
        let track = MusicObserver.shared.currentTrack
        button.image = renderStatusIcon(track: track)
        button.attributedTitle = NSAttributedString()  // Clear any old title
    }
    
    /// Render the menu bar icon as an NSImage for precise positioning.
    /// - Star: ★ (solid) if favorited, ☆ (empty) if not — 18pt
    /// - Rating number: top-right of star, 45% size
    /// - × dislike: bottom-right of star (same x as number), 45%+1pt size
    private func renderStatusIcon(track: TrackInfo?) -> NSImage {
        let menuBarHeight: CGFloat = 22
        let starSize: CGFloat = 18
        let numSize: CGFloat = starSize * 0.45
        let xSize: CGFloat = numSize + 1  // 1pt larger than number
        
        let starFont = NSFont.systemFont(ofSize: starSize, weight: .regular)
        let numFont = NSFont.systemFont(ofSize: numSize, weight: .semibold)
        let xFont = NSFont.systemFont(ofSize: xSize, weight: .semibold)
        
        guard let track = track else {
            // No track: draw an empty star
            let starChar: NSString = "☆"
            let starBounds = starChar.size(withAttributes: [.font: starFont])
            let image = NSImage(size: NSSize(width: ceil(starBounds.width), height: menuBarHeight), flipped: false) { _ in
                let y = (menuBarHeight - starBounds.height) / 2 - 0.5
                starChar.draw(at: NSPoint(x: 0, y: y), withAttributes: [.font: starFont])
                return true
            }
            image.isTemplate = true
            return image
        }
        
        let starChar: NSString = track.favorited ? "★" : "☆"
        let starBounds = starChar.size(withAttributes: [.font: starFont])
        
        let hasNumber = track.rating > 0
        let hasDislike = track.disliked
        
        // Calculate annotation column width (number and × share the same x)
        var annotWidth: CGFloat = 0
        if hasNumber {
            let numStr = NSString(string: "\(track.rating)")
            annotWidth = max(annotWidth, numStr.size(withAttributes: [.font: numFont]).width)
        }
        if hasDislike {
            let xStr: NSString = "●"
            annotWidth = max(annotWidth, xStr.size(withAttributes: [.font: xFont]).width)
        }
        
        let totalWidth = starBounds.width + (annotWidth > 0 ? annotWidth + 1 : 0)
        
        let image = NSImage(size: NSSize(width: ceil(totalWidth), height: menuBarHeight), flipped: false) { _ in
            // Draw star, centered vertically but 0.5pt lower
            let starY = (menuBarHeight - starBounds.height) / 2 - 0.5
            starChar.draw(at: NSPoint(x: 0, y: starY), withAttributes: [.font: starFont])
            
            let annotX = starBounds.width + 1  // Right edge of star + 1pt gap
            
            // Draw rating number at top-right (aligned with star top)
            if hasNumber {
                let numStr = NSString(string: "\(track.rating)")
                let numBounds = numStr.size(withAttributes: [.font: numFont])
                let numY = menuBarHeight - numBounds.height - 2  // 2pt from top
                numStr.draw(at: NSPoint(x: annotX, y: numY), withAttributes: [.font: numFont])
            }
            
            // Draw ● at bottom-right (same x as number, aligned with star bottom)
            if hasDislike {
                let xStr: NSString = "●"
                let xY: CGFloat = 1  // 1pt from bottom, aligned with star bottom edge
                xStr.draw(at: NSPoint(x: annotX, y: xY), withAttributes: [.font: xFont])
            }
            
            return true
        }
        
        image.isTemplate = true  // Adapts to light/dark menu bar automatically
        return image
    }
    
    // MARK: - Floating Panel (no arrow)
    
    private func setupPanel() {
        let hostingView = NSHostingView(rootView: PopoverView())
        
        // Let the hosting view size itself from SwiftUI content
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.contentView = hostingView
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        
        self.panelWindow = panel
    }
    
    private func togglePanel() {
        guard let panel = panelWindow, let button = statusItem?.button else { return }
        
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel(relativeTo: button)
        }
    }
    
    private func showPanel(relativeTo button: NSStatusBarButton) {
        guard let panel = panelWindow,
              let buttonWindow = button.window else { return }
        
        // Re-compute content size (may have changed due to lyrics loading)
        if let hostingView = panel.contentView {
            let size = hostingView.fittingSize
            panel.setContentSize(size)
        }
        
        // Position panel below the status item
        let buttonFrame = button.convert(button.bounds, to: nil)
        let screenFrame = buttonWindow.convertToScreen(buttonFrame)
        
        let panelWidth = panel.frame.width
        let panelHeight = panel.frame.height
        
        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.minY - panelHeight - 4  // 4pt gap below menu bar
        
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        // Monitor for clicks outside the panel
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.hidePanel()
        }
    }
    
    private func hidePanel() {
        panelWindow?.orderOut(nil)
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }
    
    // MARK: - Settings Menu (Alt-Click / Right-Click)
    
    @objc func showSettingsMenu() {
        let menu = NSMenu()
        
        // Auto-fetch Lyrics toggle
        let autoLyricsItem = NSMenuItem(
            title: "Auto-fetch Lyrics",
            action: #selector(toggleAutoFetchLyrics),
            keyEquivalent: ""
        )
        autoLyricsItem.target = self
        autoLyricsItem.state = SettingsManager.shared.settings.autoFetchLyrics ? .on : .off
        menu.addItem(autoLyricsItem)
        
        // Auto-fetch Artwork toggle
        let autoArtworkItem = NSMenuItem(
            title: "Auto-fetch Artwork",
            action: #selector(toggleAutoFetchArtwork),
            keyEquivalent: ""
        )
        autoArtworkItem.target = self
        autoArtworkItem.state = SettingsManager.shared.settings.autoFetchArtwork ? .on : .off
        menu.addItem(autoArtworkItem)
        
        menu.addItem(.separator())
        
        // Auto-write Lyrics if empty
        let autoWriteLyricsItem = NSMenuItem(
            title: "Auto-write Lyrics to File",
            action: #selector(toggleAutoWriteLyrics),
            keyEquivalent: ""
        )
        autoWriteLyricsItem.target = self
        autoWriteLyricsItem.state = SettingsManager.shared.settings.autoWriteLyrics ? .on : .off
        menu.addItem(autoWriteLyricsItem)
        
        // Auto-write Artwork if empty
        let autoWriteArtworkItem = NSMenuItem(
            title: "Auto-write Artwork to File",
            action: #selector(toggleAutoWriteArtwork),
            keyEquivalent: ""
        )
        autoWriteArtworkItem.target = self
        autoWriteArtworkItem.state = SettingsManager.shared.settings.autoWriteArtwork ? .on : .off
        menu.addItem(autoWriteArtworkItem)
        
        menu.addItem(.separator())
        
        // Genius API Key
        let apiKeyItem = NSMenuItem(
            title: SettingsManager.shared.hasGeniusKey ? "Update Genius API Key..." : "Set Genius API Key...",
            action: #selector(promptGeniusKey),
            keyEquivalent: ""
        )
        apiKeyItem.target = self
        menu.addItem(apiKeyItem)
        
        menu.addItem(.separator())
        
        // About
        let aboutItem = NSMenuItem(title: "About", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        
        menu.addItem(.separator())
        
        // Quit
        let quitItem = NSMenuItem(title: "Quit Starmania", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        // Show menu
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.menu = nil
        }
    }
    
    @objc private func toggleAutoFetchLyrics() {
        SettingsManager.shared.settings.autoFetchLyrics.toggle()
        SettingsManager.shared.save()
    }
    
    @objc private func toggleAutoFetchArtwork() {
        SettingsManager.shared.settings.autoFetchArtwork.toggle()
        SettingsManager.shared.save()
    }
    
    @objc private func toggleAutoWriteLyrics() {
        SettingsManager.shared.settings.autoWriteLyrics.toggle()
        SettingsManager.shared.save()
    }
    
    @objc private func toggleAutoWriteArtwork() {
        SettingsManager.shared.settings.autoWriteArtwork.toggle()
        SettingsManager.shared.save()
    }
    
    @objc private func promptGeniusKey() {
        showGeniusKeySetup()
    }
    
    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Starmania"
        alert.informativeText = "A macOS menu bar app to rate songs in Apple Music and to fetch lyrics and artwork.\n\n© 2026 shmvon.\n\nLyrics database: genius.com."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "GitHub")
        alert.addButton(withTitle: "Buy Me a Coffee")
        
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            if let url = URL(string: "https://github.com/shmvon") {
                NSWorkspace.shared.open(url)
            }
            // Optional: reopen the about box if they click a link
            // showAbout() 
        } else if response == .alertThirdButtonReturn {
            if let url = URL(string: "https://buymeacoffee.com/shmvon") {
                NSWorkspace.shared.open(url)
            }
            // Optional: reopen the about box if they click a link
            // showAbout()
        }
    }
    
    @objc private func quitApp() {
        MusicObserver.shared.stopPolling()
        NSApplication.shared.terminate(nil)
    }
    
    // MARK: - Genius Key Setup
    
    private func showGeniusKeySetup() {
        let alert = NSAlert()
        alert.messageText = "Genius API Key Required"
        alert.informativeText = """
        To fetch lyrics, you need a free Genius API key.
        
        1. Go to https://genius.com/api-clients
        2. Create a new API client (any name/URL)
        3. Copy the "Client Access Token"
        4. Paste it below
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open Genius Website")
        
        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        inputField.placeholderString = "Paste your Client Access Token here"
        inputField.stringValue = SettingsManager.shared.settings.geniusAPIKey
        alert.accessoryView = inputField
        
        let response = alert.runModal()
        
        switch response {
        case .alertFirstButtonReturn:
            let key = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                SettingsManager.shared.settings.geniusAPIKey = key
                SettingsManager.shared.save()
            }
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(URL(string: "https://genius.com/api-clients")!)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showGeniusKeySetup()
            }
        default:
            break
        }
    }
}
