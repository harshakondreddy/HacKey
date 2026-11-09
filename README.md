# HacKey

HacKey is a local-first macOS keyboard navigation tool inspired by Vimium and Homerow. It scans the frontmost window's Accessibility tree, displays keyboard labels over actionable elements, and lets you click or scroll without reaching for the mouse.

> **Status: In development.** Features and setup instructions may change. Accessibility coverage varies by application.

## Requirements

- macOS 13 (Ventura) or later.
- Xcode Command Line Tools for building and testing with Swift.
- Accessibility permission for the built `Hackey` executable.

## Build and Run

1. Download or clone this repository.
2. Open a terminal in the repository folder containing `Package.swift`.
3. Run `swift build`.
4. Start HacKey with `swift run` or `./.build/debug/Hackey`.

The debug executable is produced at `.build/debug/Hackey`. The executable name is `Hackey`, even though the repository is named `HacKey`.

For development, keep the terminal session open while the app runs. Console diagnostics are available there. A **Hackey** item appears in the macOS menu bar.

### First Launch: Accessibility Permission

When prompted, grant access under **System Settings → Privacy & Security → Accessibility**.

HacKey requires this permission to inspect application interfaces and perform interactions. If permission appears enabled but interactions do not work, quit HacKey, check that the entry corresponds to the executable you are running, and relaunch. You may need to remove and re-add the Accessibility entry.

### Restarting After Changes

Quit the existing instance through **Hackey → Quit Hackey** before rebuilding and relaunching. Avoid running multiple instances: they can compete for global shortcuts and event handling.

Run `swift build` after changes, then start the executable again.

## Tests

Run `swift test` from the repository folder.

The current unit tests cover label-generation properties, including uniqueness, fixed-width/prefix-free behavior, and numeric-label cycling. They do not establish end-to-end compatibility with every macOS application.

## Default Global Shortcuts

| Action | Shortcut |
|---|---|
| Toggle Click mode | `Cmd+Shift+K` |
| Toggle Click mode, secondary shortcut | `Cmd+Option+K` |
| Toggle Scroll mode | `Cmd+Shift+J` |

These shortcuts use two modifiers to reduce conflicts with ordinary typing. They can still conflict with shortcuts configured in other applications.

## Click Mode

Activate Click mode over an application window. HacKey displays short labels over the actionable elements it finds.

- **Search:** Type letters, numbers, spaces, or `_ - . /` to search visible target text. Matching is case-insensitive, ranked by exact match, prefix, then substring. Press `Return` to click the focused result.
- **Direct label selection:** Hold `Option` while typing the badge letters. For a `dt` badge, use `Option+D`, then `Option+T`. The target is clicked without pressing Return.
- **Cycle targets:** Use `Tab` to move forward or `Ctrl+Y` to move backward.
- **Left-click:** `Return`.
- **Right-click:** `Shift+Return`.
- **Command-click:** `Cmd+Return`, for example to open a supported link in a new tab.
- **Edit search:** `Delete` or `Backspace` removes the last character.
- **Exit:** `Escape` leaves Click mode without clicking.

## Scroll Mode

Activate Scroll mode to find scrollable areas in the frontmost window.

- `H`, `J`, `K`, `L`: Scroll left, down, up, or right in the focused area.
- `0`–`9`: Select a numbered scrollable area.
- `Tab` / `Ctrl+Y`: Cycle forward or backward through scrollable areas.
- `Escape`: Exit Scroll mode.

## Menu Bar Controls

The **Hackey** menu includes:

- **Activate Click Mode / Activate Scroll Mode:** Enter a navigation mode without using its shortcut.
- **Show Diagnostics:** Open the status window.
- **Run System Coverage Audit:** Inspect target coverage across supported applications and windows for diagnostics.
- **Toggle Labels-only Mode:** Disable text search and use only Option-modified badge selection.
- **Ignore/Un-ignore Current App:** Control whether HacKey activates over the current application.
- **Reload Settings:** Reload the settings file without restarting.
- **Reveal Settings File in Finder:** Locate the settings file.
- **Quit Hackey:** Stop the application.

## Settings

Settings are stored at `~/Library/Application Support/Hackey/settings.json`. The file is created with defaults on first launch.

Quit HacKey before editing, or use **Reload Settings** after saving changes. Preserve valid JSON.

| Setting | Purpose |
|---|---|
| `clickActivationPrimary` | Primary Click-mode shortcut. |
| `clickActivationSecondary` | Secondary Click-mode shortcut. |
| `scrollActivation` | Scroll-mode shortcut. |
| `labelsOnlyMode` | Enable badge selection without text search. |
| `scrollSpeed` | Scroll distance in pixels per navigation keystroke. |
| `maxTargets` | Maximum targets displayed for a scan. |
| `ignoredBundleIDs` | Application bundle identifiers excluded from activation. |

Shortcut settings contain `key`, `keyCode`, and `modifiers`. Supported modifier names are `command`, `shift`, `option`, and `control`.

## Architecture

- **`AXElementScanner.swift`:** Traverses the frontmost application's Accessibility tree within depth, time, and node-count limits, filtering and deduplicating interaction targets.
- **`HackeyCoordinator.swift`:** Manages navigation modes, search state, target focus, and keyboard dispatch.
- **`HotkeyMonitor.swift`:** Handles global shortcuts and captures navigation keystrokes through a `CGEventTap`.
- **`InteractionPerformer.swift`:** Performs clicks and scrolling using synthetic `CGEvent` input at target coordinates.
- **`OverlayManager.swift`:** Draws target-label overlays across screens.
- **`SettingsStore.swift`:** Loads and saves settings.
- **`AppDelegate.swift`:** Handles application lifecycle and the menu bar interface.

## Known Limitations

- Labels may overlap in dense interfaces. Confirm the focused target before activating it.
- Accessibility coverage depends on the application's framework and implementation. Some Electron and custom-drawn interfaces may expose fewer actionable elements.
- Shortcut remapping currently requires editing `settings.json`; an in-app remapping interface is not available.
- Generated input can trigger real application actions. Use care around destructive controls and permission dialogs.

## Development Notes

- Keep generated `.build/` output out of version control; Swift regenerates it locally.
- Keep source, tests, and `Package.swift` together when building the project.
- The local `references/` folder is not part of this repository. Upstream inspiration is linked below rather than bundled.

## References

HacKey draws inspiration from:

- [Vimium](https://github.com/philc/vimium): Keyboard navigation for the browser.
- [vimac](https://github.com/nchudleigh/vimac): Vimium-style keyboard navigation for macOS.
- [homerow](https://github.com/nchudleigh/homerow): Keyboard-driven clicking and scrolling for macOS.

## Privacy and Project Scope

HacKey is intended for local personal use. It accesses application interface information through macOS Accessibility APIs to identify navigation targets.

The project has no license-key, payment, or telemetry functionality. This development version is not a packaged installer or a production-readiness guarantee.
