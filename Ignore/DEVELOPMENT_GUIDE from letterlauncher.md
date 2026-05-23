# LetterLauncher — Development Guide

> A macOS menu-bar application launcher with keyboard-driven navigation.
> Built with Swift 6, SwiftUI, and AppKit. No external dependencies.

---

## 1. What the App Does

LetterLauncher is a background macOS app (no Dock icon) that:

- Runs as a **menu bar item** showing an italic "LL" icon.
- Responds to **two global hotkeys**: one to show all applications, another to show only favourited apps.
- Displays a **floating overlay** with a grid of app icons discovered from `/Applications`, `/System/Applications`, and `~/Applications`.
- Supports **letter-key cycling** (press "S" to jump through Safari, Slack, Spotify…), **arrow navigation**, **Enter to launch**, **Esc to close**, and **Space to star/unstar**.
- Persists favourites and hotkey configuration in `~/Library/Application Support/LetterLauncher/settings.json`.
- Is fully self-contained in a `.app` bundle (binary + Info.plist + icon) that can be zipped and shared.

---

## 2. Project Structure

```
AppLauncher/
├── Package.swift                 # Swift Package Manager manifest
├── Sources/LetterLauncher/
│   ├── LetterLauncher.swift      # @main entry, AppDelegate, window & menu bar setup
│   ├── HotkeyManager.swift       # Global/local NSEvent monitors + LauncherPanel subclass
│   ├── SettingsManager.swift     # HotkeyConfig, AppSettings, JSON persistence
│   ├── ViewState.swift           # Observable state: visibility, mode, selection, key handling
│   ├── LauncherView.swift        # SwiftUI grid view + AppItemView
│   └── AppDiscoverer.swift       # Enumerates apps from system directories
└── LetterLauncher.app/           # Pre-built app bundle shell
    └── Contents/
        ├── Info.plist
        ├── MacOS/LetterLauncher  # The compiled binary (copied after `swift build`)
        └── Resources/AppIcon.icns
```

The app is built with `swift build` (Swift Package Manager) and then the binary is manually copied into the `.app` bundle. There is no Xcode project.

---

## 3. Architecture Overview

```
┌─────────────────────┐
│   HotkeyManager     │  Singleton. Installs NSEvent global+local monitors.
│   (event layer)     │  Matches keyDown events against cached HotkeyConfigs.
│                     │  Fires onAllApps / onFavorites callbacks.
└────────┬────────────┘
         │ callbacks
         ▼
┌─────────────────────┐
│   AppDelegate       │  Sets up LauncherPanel, menu bar, wires callbacks.
│   (coordination)    │  On show: makeKeyAndOrderFront + activate.
│                     │  Installs local navigation monitor + click-outside monitor.
└────────┬────────────┘
         │ ViewState.shared.$isVisible
         ▼
┌─────────────────────┐      ┌──────────────────┐
│   ViewState         │◄────►│ SettingsManager   │
│   (state machine)   │      │ (persistence)     │
│   - isVisible       │      │ - hotkeys         │
│   - mode            │      │ - favorites []    │
│   - selectedIndex   │      └──────────────────┘
│   - displayedApps   │
│   - handleKeyDown() │◄──── AppDiscoverer (app list)
└────────┬────────────┘
         │ @Published
         ▼
┌─────────────────────┐
│   LauncherView      │  SwiftUI. LazyVGrid of AppItemView.
│   (presentation)    │  Renders icons, names, stars, selection highlight.
└─────────────────────┘
```

---

## 4. Critical macOS Pitfalls (Lessons Learned)

These are the hard-won insights. Each one caused real bugs that were difficult to diagnose.

### 4.1 Window Must Become Key — Or Keystrokes Go Elsewhere

**Problem:** Using `NSPanel` with `.nonactivatingPanel` style means the panel literally *cannot* become the key window. All keyboard events continue going to whatever app was previously active. The user types into their text editor while looking at your launcher.

**Solution:** Subclass `NSPanel` and override `canBecomeKey` to return `true`. Remove `.nonactivatingPanel` from the style mask. Call `panel.makeKeyAndOrderFront(nil)` and `NSApplication.shared.activate(ignoringOtherApps: true)` when showing the launcher.

```swift
class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { return true }
}
```

**CAUTION:** Without this, `addLocalMonitorForEvents` will never fire for the panel, and `addGlobalMonitorForEvents` cannot consume events — the previous app still receives every keystroke.

### 4.2 Never Use `CGEvent.tapCreate` for Cmd-Based Shortcuts

**Problem:** `CGEvent.tapCreate` requires Accessibility permissions. macOS silently revokes these permissions every time the binary changes (i.e., every rebuild). The user must manually re-add the app in System Settings each time. This is a terrible developer experience.

**Solution:** Use `NSEvent.addGlobalMonitorForEvents` instead. It works for shortcuts that include `Cmd` or `Ctrl` modifiers without needing any special permissions. Only use CGEvent taps if you need to intercept events that `NSEvent` monitors cannot see (e.g., bare modifier-only keys).

### 4.3 Never Call `DispatchQueue.main.sync` from a CGEvent Tap Callback

**Problem:** CGEvent tap callbacks can run on the main thread. Calling `DispatchQueue.main.sync` from the main thread is an instant deadlock. The app freezes before even creating its menu bar icon. There is no crash log — the process just hangs.

**Solution:** If you must use CGEvent taps, cache any state you need to read (like hotkey configurations) on the manager object itself. Never cross actor boundaries synchronously from within the callback.

### 4.4 `NSEvent.ModifierFlags` Contains Hidden Flags

**Problem:** `event.modifierFlags.intersection(.deviceIndependentFlagsMask)` includes `.function` and `.numericPad` — which are set for arrow keys, Home, End, etc. If you compare the full mask with `== requiredFlags`, arrow keys will never match a simple `[.control]` config, but more importantly, a letter-jump guard like `if mods.isEmpty` will be unreliable.

**Solution:** Only extract and compare the 4 modifier keys you care about:

```swift
let hasModifier = flags.contains(.command) || flags.contains(.option) || flags.contains(.control)
```

### 4.5 SwiftUI View Identity in ForEach + LazyVGrid

**Problem:** When using `ForEach(Array(items.enumerated()), id: \.element.id)` and then adding `.id(index)` for `ScrollViewReader`, the `.id(index)` **overrides** the ForEach identity. SwiftUI caches the view for `.id(0)` and reuses it when the underlying array changes. Switching from a 200-item all-apps list to a 6-item favourites list shows stale icons from the all-apps list at indices 0–5, while tap targets point to the correct favourites.

**Solution:** Always use the model's stable identity for `.id()`:

```swift
.id(app.id)  // UUID — not the array index
```

And scroll to the model identity:

```swift
proxy.scrollTo(displayedApps[newIndex].id, anchor: .center)
```

**WARNING:** This bug is visually deceptive: the icons look wrong but tapping them launches the correct (invisible) app. It appears as "random apps in favourites" but is actually a stale view cache.

### 4.6 Global Monitor Stacking

**Problem:** If `showLauncher()` installs a new `NSEvent.addGlobalMonitorForEvents` each time it's called, and `$isVisible` emits `true` redundantly (e.g., when toggling modes while already visible), monitors stack up. Each one fires for every event, causing arrow keys to move 2, 3, or more positions per press.

**Solution:**
1. Add `.removeDuplicates()` to the `$isVisible` publisher so it only fires on actual changes.
2. Always call `removeMonitors()` at the start of `showLauncher()` before installing new ones.

### 4.7 Click-Outside Detection

**Problem:** `NSEvent.addGlobalMonitorForEvents` receives events from *other* apps. The `event.locationInWindow` property is in the *other* window's coordinate space — useless for checking if the click is inside your panel.

**Solution:** Use `NSEvent.mouseLocation` (screen coordinates) and check against `panel.frame`:

```swift
let mouse = NSEvent.mouseLocation
if !panel.frame.contains(mouse) { dismiss() }
```

### 4.8 `NSAlert.runModal()` Blocks the Run Loop

**Problem:** When recording a hotkey, `runModal()` blocks the thread. If the event monitor captures a key and tries to show a confirmation alert, both alerts coexist.

**Solution:** Call `NSApplication.shared.abortModal()` to programmatically dismiss the blocking alert, then show the confirmation after a short delay (`asyncAfter`).

### 4.9 Transparent Rounded Corners with "Reduce Transparency"

**Problem:** `NSVisualEffectView` with `layer.cornerRadius` renders opaque corners when the user has "Reduce Transparency" enabled in System Settings.

**Solution:** Use SwiftUI's `.background(.ultraThinMaterial)` combined with `.cornerRadius()` on the root view. Set `panel.backgroundColor = .clear` and `panel.isOpaque = false`. SwiftUI handles the material rendering correctly regardless of the transparency setting.

### 4.10 `LSUIElement` and Activation Policy

The app runs as a background agent (no Dock icon). This requires:
- `LSUIElement = true` in `Info.plist`
- `NSApplication.shared.setActivationPolicy(.accessory)` in `applicationWillFinishLaunching`

But when showing the launcher, you must call `activate(ignoringOtherApps: true)` or the panel won't receive keyboard focus despite `canBecomeKey = true`.

---

## 5. Hotkey Matching Strategy

Hotkeys are stored as `(keyCode: Int, modifiers: [String])`. This is **keyboard-layout independent** — keyCode 38 is always the physical "J" key regardless of whether the user's layout is QWERTY, AZERTY, or Dvorak.

The matching function extracts only `cmd/shift/opt/ctrl` from the event's modifier flags and compares them against the stored config. This avoids false negatives from `.function` or `.numericPad` flags that macOS adds to certain keys.

Recording a new hotkey: set a `recordingTarget` flag, and the next `keyDown` event captured by any monitor is saved as the new config. The listening alert is dismissed via `abortModal()`.

---

## 6. Favourites Tracking

Favourites are stored as **absolute file paths** (e.g., `/Applications/Typora.app`). This avoids name collisions — multiple apps can share the same display name (e.g., `StataMP.app` exists in three different directories).

The path used for comparison must be exactly `app.url.path` as produced by `AppDiscoverer`. Do NOT normalise paths with `URL.standardized` or `resolvingSymlinksInPath()` — these can change paths in unexpected ways and break the `Set.contains()` check.

---

## 7. App Discovery

`AppDiscoverer` uses `FileManager.enumerator` with `skipsPackageDescendants` to recursively walk `/Applications`, `/System/Applications`, `/System/Applications/Utilities`, and `~/Applications`. It resolves Finder aliases via `URL(resolvingAliasFileAt:)`. Apps are deduplicated by URL and sorted alphabetically.

Icons are loaded with `NSWorkspace.shared.icon(forFile:)`.

Discovery runs on a background queue; results are published to the main actor via `@Published var apps`.

---

## 8. Build & Deploy

```bash
# Build
swift build

# Copy binary into the .app bundle
cp .build/debug/LetterLauncher LetterLauncher.app/Contents/MacOS/

# Launch
open LetterLauncher.app
```

The `.app` bundle must contain:
- `Contents/Info.plist` (with `LSUIElement`, `CFBundleExecutable`, `CFBundleIconFile`)
- `Contents/MacOS/LetterLauncher` (the binary)
- `Contents/Resources/AppIcon.icns` (the icon)

To create the `.icns` from a PNG: use `sips` to generate multiple sizes into a `.iconset` directory, then `iconutil -c icns` to compile.

**TIP:** If building on Google Drive or any cloud-synced directory, you will see spurious `disk I/O error` messages on the build database. The binary is still produced correctly. Move the project to a local directory (e.g., `~/Developer/`) to eliminate these.

---

## 9. Swift 6 Concurrency Considerations

The project uses Swift 6 strict concurrency (`swiftLanguageModes: [.v6]`). Key rules:

- `SettingsManager` and `ViewState` are `@MainActor`. Their `@Published` properties can only be accessed from the main actor.
- `HotkeyManager` is `@unchecked Sendable`. It caches hotkey configs locally (via `refreshCachedSettings()` called from the main actor) so that its `NSEvent` monitor callbacks can read them without crossing actor boundaries.
- Never access `@MainActor` properties from `NSEvent` monitor callbacks with `DispatchQueue.main.sync` — use cached copies or `DispatchQueue.main.async`.

---

## 10. Summary of Iteration History

| Iteration | What went wrong | Root cause |
|-----------|----------------|------------|
| 1 | App wouldn't launch | `DispatchQueue.main.sync` deadlock in CGEvent tap |
| 2 | Hotkeys didn't fire | CGEvent tap requires Accessibility permission; revoked on rebuild |
| 3 | Recording didn't work | `NSAlert.runModal()` blocked the run loop |
| 4 | Navigation jumped 2 tiles | Global monitors stacked on repeated show calls |
| 5 | Favourites showed wrong icons | `.id(index)` caused SwiftUI to reuse stale cached views |
| 6 | Couldn't type in launcher | `.nonactivatingPanel` prevented the panel from becoming key |
| 7 | Typing leaked to previous app | Same as above — panel never received focus |
| 8 | Rounded corners not transparent | `NSVisualEffectView` ignores corner radius with Reduce Transparency |

Each of these is a macOS-specific platform behaviour that is not obvious from documentation alone. The pitfalls in §4 are the essential knowledge for building this type of app correctly on the first attempt.
