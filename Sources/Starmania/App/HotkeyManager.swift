import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon `RegisterEventHotKey` (no Accessibility permission needed):
/// ⌃⌥1–5 rate the current track, ⌃⌥0 clears the rating, ⌃⌥F toggles favorite, ⌃⌥D toggles dislike,
/// plus a user-chosen shortcut that shows the panel.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var actions: [UInt32: () -> Void] = [:]
    private var panelHotKeyRef: EventHotKeyRef?
    private var panelAction: (() -> Void)?
    private let panelHotKeyID: UInt32 = 100

    private init() {}

    var isEnabled: Bool { !hotKeyRefs.isEmpty }

    func setEnabled(_ enabled: Bool) {
        if enabled { register() } else { unregister() }
    }

    private func register() {
        guard hotKeyRefs.isEmpty else { return }
        installHandlerIfNeeded()

        let music = MusicObserver.shared
        let digitKeys = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5]
        var bindings: [(keyCode: Int, action: () -> Void)] = digitKeys.enumerated().map { stars, key in
            (key, { music.setRating(stars) })
        }
        bindings.append((kVK_ANSI_F, {
            if let track = music.currentTrack { music.setFavorited(!track.favorited) }
        }))
        bindings.append((kVK_ANSI_D, {
            if let track = music.currentTrack { music.setDisliked(!track.disliked) }
        }))

        let modifiers = UInt32(controlKey | optionKey)
        for (index, binding) in bindings.enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x53544152), id: id)  // 'STAR'
            let status = RegisterEventHotKey(UInt32(binding.keyCode), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
                actions[id] = binding.action
            } else {
                print("[Starmania] Could not register hotkey \(id) (status \(status))")
            }
        }
    }

    private func unregister() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        actions.removeAll()
    }

    /// Register (or with nil, remove) the shortcut that shows the panel. Returns false when
    /// macOS refuses it, usually because another app already uses that combination.
    @discardableResult
    func setPanelHotkey(_ combo: KeyCombo?, action: @escaping () -> Void) -> Bool {
        if let ref = panelHotKeyRef {
            UnregisterEventHotKey(ref)
            panelHotKeyRef = nil
        }
        panelAction = action
        guard let combo else { return true }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x53544152), id: panelHotKeyID)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            print("[Starmania] Could not register panel shortcut \(combo.display) (status \(status))")
            return false
        }
        panelHotKeyRef = ref
        return true
    }

    fileprivate func handle(id: UInt32) {
        if id == panelHotKeyID {
            panelAction?()
        } else {
            actions[id]?()
        }
    }

    // MARK: - Recording

    /// Carbon modifier mask for AppKit modifier flags.
    nonisolated static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        return mask
    }

    /// "⌃⌥⇧⌘" + key, in the order macOS menus use.
    nonisolated static func displayString(modifiers flags: NSEvent.ModifierFlags, key: String) -> String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + key
    }

    /// Readable name of the key in a key-down event.
    nonisolated static func keyName(keyCode: UInt16, characters: String?) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = special[Int(keyCode)] { return name }
        return (characters ?? "?").uppercased()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            // Carbon delivers hotkey events on the main thread
            MainActor.assumeIsolated {
                HotkeyManager.shared.handle(id: id)
            }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
    }
}
