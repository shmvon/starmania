import AppKit
import Carbon.HIToolbox

/// Global rating hotkeys via Carbon `RegisterEventHotKey` (no Accessibility permission needed):
/// ⌃⌥1–5 rate the current track, ⌃⌥0 clears the rating, ⌃⌥F toggles favorite, ⌃⌥D toggles dislike.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var actions: [UInt32: () -> Void] = [:]

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

    fileprivate func handle(id: UInt32) {
        actions[id]?()
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
