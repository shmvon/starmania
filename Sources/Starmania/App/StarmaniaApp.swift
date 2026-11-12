import SwiftUI
import AppKit
import Combine

@main
struct StarmaniaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Starmania", isInserted: .constant(false)) {
            EmptyView()
        }
    }
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var panelWindow: NSPanel?
    private let panelState = PanelState()
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var clickMonitor: Any?
    private var modifierTimer: Timer?
    /// Suggestions are waiting: the icon pulses while the panel is closed.
    private var needsAttention = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApplication.shared.setActivationPolicy(.accessory)
        
        // Setup menu bar item
        setupStatusItem()
        
        // Setup floating panel (no arrow, unlike NSPopover)
        setupPanel()
        
        // Start music observer and the lyrics/artwork controller
        NowPlayingController.shared.start()
        SuggestionCenter.shared.start()
        MusicObserver.shared.startPolling()

        SuggestionCenter.shared.$suggestions
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { [weak self] pending in
                self?.needsAttention = pending
                self?.updatePulse()
            }
            .store(in: &cancellables)

        // The panel's height changes with suggestions and when a track starts or stops
        Publishers.Merge3(
            SuggestionCenter.shared.$suggestions.map { $0.count }.removeDuplicates().map { _ in () },
            MusicObserver.shared.$currentTrack.map { $0 == nil }.removeDuplicates().map { _ in () },
            SettingsManager.shared.$settings.map(\.panelPage).removeDuplicates().map { _ in () }
        )
        .debounce(for: .seconds(0.05), scheduler: RunLoop.main)
        .sink { [weak self] in self?.resizePanelKeepingTop() }
        .store(in: &cancellables)
        
        // Observe track changes to update menu bar icon
        MusicObserver.shared.$currentTrack
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)
        
        // Global rating hotkeys follow the setting
        SettingsManager.shared.$settings
            .map(\.ratingHotkeysEnabled)
            .removeDuplicates()
            .sink { enabled in
                HotkeyManager.shared.setEnabled(enabled)
            }
            .store(in: &cancellables)

        // The shortcut that shows the panel
        SettingsManager.shared.$settings
            .map(\.panelHotkey)
            .removeDuplicates()
            .sink { [weak self] combo in
                HotkeyManager.shared.setPanelHotkey(combo) { self?.togglePanel() }
            }
            .store(in: &cancellables)
    }
    
    /// Write any queued tag changes before quitting, so they aren't lost.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MusicObserver.shared.stopPolling()
        Task {
            await NowPlayingController.shared.flushAllPendingWrites()
            await MusicObserver.shared.flushPendingEdits()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return false
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
        let event = NSApp.currentEvent
        let isOption = event?.modifierFlags.contains(.option) ?? false
        let isRight = event?.type == .rightMouseUp
        
        if isOption || isRight {
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
            let starRect = NSRect(x: 2, y: 1, width: starSize, height: menuBarHeight)
            let totalWidth: CGFloat = starSize + 4
            let icon = NSImage(size: NSSize(width: totalWidth, height: menuBarHeight))
            icon.lockFocus()
            starChar.draw(in: starRect, withAttributes: [
                .font: starFont,
                .foregroundColor: NSColor.labelColor
            ])
            icon.unlockFocus()
            icon.isTemplate = false
            return icon
        }
        
        let isFav = track.favorited
        let isDis = track.disliked
        let rating = track.rating
        
        // Star glyph: solid if favorited, else hollow
        let starChar: NSString = isFav ? "★" : "☆"
        
        // Annotations:
        // Top-right: rating number (1-5), or empty
        let topStr: String? = rating > 0 ? "\(rating)" : nil
        // Bottom-right: dislike ×, or rating number if disliked+rated
        let bottomStr: String? = isDis ? "×" : nil
        
        // Measure elements to determine total image width
        let starBounds = starChar.size(withAttributes: [.font: starFont])
        var annotWidth: CGFloat = 0
        if let topStr = topStr {
            let topNS = topStr as NSString
            annotWidth = max(annotWidth, topNS.size(withAttributes: [.font: numFont]).width)
        }
        if let bottomStr = bottomStr {
            let bottomNS = bottomStr as NSString
            annotWidth = max(annotWidth, bottomNS.size(withAttributes: [.font: xFont]).width)
        }
        
        let totalWidth = starBounds.width + (annotWidth > 0 ? annotWidth + 1 : 0)
        
        let image = NSImage(size: NSSize(width: ceil(totalWidth), height: menuBarHeight), flipped: false) { _ in
            // Draw star, centered vertically but 0.5pt lower
            let starY = (menuBarHeight - starBounds.height) / 2 - 0.5
            starChar.draw(at: NSPoint(x: 0, y: starY), withAttributes: [.font: starFont])
            
            let annotX = starBounds.width + 1  // Right edge of star + 1pt gap
            
            // Draw rating number at top-right (aligned with star top)
            if let topStr = topStr {
                let topNS = topStr as NSString
                let numBounds = topNS.size(withAttributes: [.font: numFont])
                let numY = menuBarHeight - numBounds.height - 2  // 2pt from top
                topNS.draw(at: NSPoint(x: annotX, y: numY), withAttributes: [.font: numFont])
            }
            
            // Draw dislike/rating at bottom-right (same x as number, aligned with star bottom)
            if let bottomStr = bottomStr {
                let bottomNS = bottomStr as NSString
                let xY: CGFloat = 1  // 1pt from bottom, aligned with star bottom edge
                bottomNS.draw(at: NSPoint(x: annotX, y: xY), withAttributes: [.font: xFont])
            }
            
            return true
        }
        
        image.isTemplate = true  // Adapts to light/dark menu bar automatically
        return image
    }
    
    /// Gently pulse the icon while suggestions wait and the panel is closed (not with Reduce Motion).
    private func updatePulse() {
        guard let button = statusItem?.button else { return }
        button.wantsLayer = true
        let shouldPulse = needsAttention && !panelState.isVisible
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shouldPulse {
            guard button.layer?.animation(forKey: "pulse") == nil else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.3
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            button.layer?.add(pulse, forKey: "pulse")
        } else {
            button.layer?.removeAnimation(forKey: "pulse")
        }
    }
    
    // MARK: - Floating Panel (no arrow)
    
    private func setupPanel() {
        let hostingView = NSHostingView(rootView: PopoverView(panel: panelState))
        // Report the SwiftUI content size (fittingSize), but don't let it resize the window:
        // the panel is resized explicitly, keeping its top edge under the menu bar
        hostingView.sizingOptions = [.intrinsicContentSize]
        
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
    
    /// Fit the panel to its content, keeping it attached below the menu bar.
    private func resizePanelKeepingTop() {
        guard let panel = panelWindow, panel.isVisible, let hostingView = panel.contentView else { return }
        let size = hostingView.fittingSize
        guard size.height != panel.frame.height || size.width != panel.frame.width else { return }
        let frame = NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        hostingView.frame = NSRect(origin: .zero, size: size)
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
            hostingView.frame = NSRect(origin: .zero, size: size)
        }
        
        // Position panel below the status item
        let buttonFrame = button.convert(button.bounds, to: nil)
        let screenFrame = buttonWindow.convertToScreen(buttonFrame)
        
        let panelWidth = panel.frame.width
        let panelHeight = panel.frame.height
        
        let x = screenFrame.midX - panelWidth / 2
        // Menu bar height is typically 24-25pt; position panel 2pt below the screen frame
        let y = screenFrame.minY - panelHeight - 7  // 7 pt below the status item: a small gap under the menu bar
        
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
        panelState.isVisible = true
        updatePulse()
        
        // Monitor clicks outside to dismiss
        startClickMonitoring()
        startModifierSampling()
    }
    
    private func hidePanel() {
        panelWindow?.orderOut(nil)
        panelState.isVisible = false
        updatePulse()
        stopClickMonitoring()
        stopModifierSampling()
    }
    
    /// The panel never becomes key, so ⌥ is sampled while it's visible rather than observed.
    private func startModifierSampling() {
        stopModifierSampling()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let pressed = NSEvent.modifierFlags.contains(.option)
                if pressed != self.panelState.isOptionPressed {
                    self.panelState.isOptionPressed = pressed
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        modifierTimer = timer
    }
    
    private func stopModifierSampling() {
        modifierTimer?.invalidate()
        modifierTimer = nil
        panelState.isOptionPressed = false
    }
    
    private func startClickMonitoring() {
        stopClickMonitoring()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let panel = self.panelWindow, panel.isVisible else { return }
                
                // Check if click was inside status item button
                if let button = self.statusItem?.button,
                   let buttonWindow = button.window {
                    let clickLoc = NSEvent.mouseLocation
                    let buttonScreenFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
                    if buttonScreenFrame.contains(clickLoc) {
                        return  // Status button clicked, will toggle via its own action
                    }
                }
                
                // Dismiss panel
                self.hidePanel()
            }
        }
    }
    
    private func stopClickMonitoring() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }
    
    // MARK: - Settings Menu (Option-click or right-click)
    
    private func showSettingsMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false  // Respect each item's isEnabled

        // The playing song: favorite, dislike and rating, with their global shortcuts
        if let track = MusicObserver.shared.currentTrack {
            addSongItems(to: menu, track: track)
            menu.addItem(.separator())
        }

        // Bulk fetch for the current album / playlist
        let controller = NowPlayingController.shared
        let bulkItem = NSMenuItem(
            title: controller.isBulkRunning ? "Stop Fetching Missing Lyrics & Artwork" : "Fetch Missing Lyrics & Artwork for Album/Playlist",
            action: #selector(toggleBulkFetch),
            keyEquivalent: ""
        )
        bulkItem.target = self
        bulkItem.isEnabled = MusicObserver.shared.currentTrack != nil || controller.isBulkRunning
        menu.addItem(bulkItem)
        
        menu.addItem(.separator())
        
        // Settings window
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
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
        if let button = statusItem?.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
        }
    }
    
    private func addSongItems(to menu: NSMenu, track: TrackInfo) {
        let title = NSMenuItem(title: track.artist.isEmpty ? track.name : "\(track.name) — \(track.artist)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let shortcuts = SettingsManager.shared.settings.ratingHotkeysEnabled
        func item(_ title: String, _ action: Selector, key: String, tag: Int = 0, on: Bool = false) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: shortcuts ? key : "")
            item.keyEquivalentModifierMask = [.control, .option]
            item.target = self
            item.tag = tag
            item.state = on ? .on : .off
            return item
        }

        menu.addItem(item("Favorite", #selector(toggleFavoriteFromMenu), key: "f", on: track.favorited))
        menu.addItem(item("Dislike", #selector(toggleDislikeFromMenu), key: "d", on: track.disliked))
        menu.addItem(.separator())
        for stars in (1...5).reversed() {
            let label = String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars)
            menu.addItem(item(label, #selector(rateFromMenu(_:)), key: "\(stars)", tag: stars, on: track.rating == stars))
        }
        let clear = item("Clear Rating", #selector(rateFromMenu(_:)), key: "0", tag: 0)
        clear.isEnabled = track.rating > 0
        menu.addItem(clear)
    }

    @objc private func toggleFavoriteFromMenu() {
        guard let track = MusicObserver.shared.currentTrack else { return }
        MusicObserver.shared.setFavorited(!track.favorited)
    }

    @objc private func toggleDislikeFromMenu() {
        guard let track = MusicObserver.shared.currentTrack else { return }
        MusicObserver.shared.setDisliked(!track.disliked)
    }

    @objc private func rateFromMenu(_ sender: NSMenuItem) {
        MusicObserver.shared.setRating(sender.tag)
    }

    @objc private func toggleBulkFetch() {
        let controller = NowPlayingController.shared
        if controller.isBulkRunning {
            controller.cancelBulkFetch()
        } else {
            controller.startBulkFetch()
        }
    }
    
    // MARK: - Settings Window
    
    @objc private func showSettingsWindow() {
        hidePanel()
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Starmania Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    
    @objc private func showAbout() {
        var shouldShow = true
        while shouldShow {
            let alert = NSAlert()
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            alert.messageText = "Starmania (\(version))"
            alert.informativeText = "A macOS menu bar app to rate songs in Apple Music and to fetch lyrics and artwork.\n\n© 2026 shmvon\n\nLyrics: LRCLIB / Lyrica, SongLyrics, Genius. Album years and genres: MusicBrainz."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "GitHub")
            alert.addButton(withTitle: "Buy Me a Coffee")
            
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                if let url = URL(string: "https://github.com/shmvon/starmania") {
                    NSWorkspace.shared.open(url)
                }
            } else if response == .alertThirdButtonReturn {
                if let url = URL(string: "https://buymeacoffee.com/shmvon") {
                    NSWorkspace.shared.open(url)
                }
            } else {
                shouldShow = false
            }
        }
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
