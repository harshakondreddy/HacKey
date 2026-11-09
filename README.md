> **Status: In development.** Features and setup instructions may change.

# Hackey

Hackey is a local-first macOS keyboard navigation tool, inspired by keyboard-driven
hint-mode tools like Vimium and Homerow. It scans the frontmost app/window's
accessibility (AX) tree, overlays a small keyboard-reachable "badge" on every
clickable/scrollable element it finds, and lets you click or scroll using only
the keyboard - no mouse/trackpad required.

## Requirements

- macOS 13 (Ventura) or later
- Xcode Command Line Tools (for `swift build`/`swift test`)
- Accessibility permission granted to the built `Hackey` binary (see below)

## Build

```bash
cd /Users/H339726/Desktop/mac-app
swift build
```

The debug binary is produced at `.build/debug/Hackey`.

## Run

```bash
./.build/debug/Hackey
```

or, equivalently:

```bash
swift run
```

### First launch: grant Accessibility permission

The first time Hackey runs, macOS will prompt you to grant it Accessibility
access (System Settings → Privacy & Security → Accessibility). Hackey cannot
scan or click anything until this is granted. If the toggle doesn't "take"
(clicking things still does nothing), remove the entry from the list and
re-launch Hackey to re-trigger the prompt.

### Normal startup sequence

1. Kill any previously running instance so you don't end up with two copies
   fighting over the same global hotkey/event tap:
   ```bash
   pkill -9 -f "\.build/debug/Hackey"
   ```
2. Rebuild if you've changed anything:
   ```bash
   swift build
   ```
3. Launch it detached, so it keeps running in the background after your
   terminal session ends:
   ```bash
   nohup ./.build/debug/Hackey > /tmp/hackey.log 2>&1 & disown
   ```
4. Confirm it's running:
   ```bash
   ps aux | grep -i hackey | grep -v grep
   ```

A "Hackey" title appears in the macOS menu bar once it's running - click it for
the menu described below.

### Running for live diagnostics

`Hackey`'s console output is fully buffered when redirected to a file, so if
you want to watch its `print()` diagnostics (scan timing, target counts, etc.)
live while you use it, run it attached to a foreground terminal instead of the
detached form above:

```bash
./.build/debug/Hackey
```

## Test

```bash
swift test
```

Runs the unit tests in `Tests/HackeyTests` (label-generation correctness:
uniqueness, fixed-width/prefix-free property, numeric-label cycling).

## Default global shortcuts

| Action | Shortcut |
|---|---|
| Activate/deactivate Click mode | `Cmd+Shift+K` |
| Activate/deactivate Click mode (secondary) | `Cmd+Option+K` |
| Activate/deactivate Scroll mode | `Cmd+Shift+J` |

These are intentionally two-modifier combos on a key (`K`/`J`) that has no
unmodified-typing meaning of its own, so they don't collide with normal typing
or other apps' single-modifier shortcuts.

## Click mode

Press the activation shortcut over any app/window to enter Click mode. Every
actionable UI element Hackey finds gets a small badge (1-3 letters, e.g. `dt`).

- **Type to search**: just type letters/numbers/spaces/`_-./`, exactly like the
  text you see on screen (case doesn't affect matching). Results are ranked
  (exact match, then prefix match, then substring match) and the best match is
  auto-focused; press `Return` to click it.
- **Label-jump (direct click)**: hold **Option (⌥)** and type a badge's letters
  (e.g. `⌥+D` then `⌥+T` for badge "dt") to click that element immediately -
  no need to press Return afterward. Option is used specifically because it is
  never part of normal typed text, so it never conflicts with typing a search
  query (even one containing capital letters).
- `Tab` / `Ctrl+Y`: cycle focus forward/backward through the currently visible
  targets.
- `Return`: left-click the focused target.
- `Shift+Return`: right-click the focused target.
- `Cmd+Return`: command-click the focused target (e.g. open link in new tab).
- `Delete`/`Backspace`: remove the last character of the search query.
- `Escape`: exit Click mode without clicking anything.

## Scroll mode

Press the scroll-activation shortcut to enter Scroll mode - Hackey finds every
scrollable area in the frontmost window and lets you pick one and scroll it.

- `H` / `J` / `K` / `L`: scroll left / down / up / right in the focused
  scrollable area.
- `0`-`9`: jump focus directly to the Nth scrollable area.
- `Tab` / `Ctrl+Y`: cycle focus forward/backward through scrollable areas.
- `Escape`: exit Scroll mode.

## Menu bar

Click the "Hackey" item in the menu bar for:

- **Activate Click Mode** / **Activate Scroll Mode** - same as the keyboard
  shortcuts, useful if you forget/remap them.
- **Show Diagnostics** - quick status window.
- **Run System Coverage Audit** - scans a set of common apps/windows and
  reports target counts (useful for sanity-checking after a scanner change).
- **Toggle Labels-only Mode** - when on, plain-text query search is disabled
  entirely and only Option+letter label-jump works (badges are the only
  interaction). Useful in apps whose own keyboard shortcuts you don't want
  typed search text to compete with.
- **Ignore/Un-ignore Current App** - adds/removes the frontmost app's bundle
  ID from the ignore list; Hackey will never activate over an ignored app
  (useful for games, remote-desktop clients, etc.).
- **Reload Settings** - re-reads `settings.json` from disk without
  restarting.
- **Reveal Settings File in Finder** - opens the settings JSON file described
  below.
- **Quit Hackey**.

## Settings

Settings persist to disk as JSON at:

```
~/Library/Application Support/Hackey/settings.json
```

This file is created with defaults on first launch and is safe to hand-edit
(use "Reload Settings" from the menu bar afterward, or relaunch). It stores:

- `clickActivationPrimary` / `clickActivationSecondary` / `scrollActivation`:
  each a `{ key, keyCode, modifiers: [...] }` combo (`modifiers` is any of
  `"command"`, `"shift"`, `"option"`, `"control"`).
- `labelsOnlyMode`: `true`/`false`.
- `scrollSpeed`: integer pixels-per-keypress for H/J/K/L scrolling.
- `maxTargets`: cap on how many hint targets a single scan will surface.
- `ignoredBundleIDs`: array of app bundle identifiers Hackey will never
  activate over.

## Architecture overview

- `AXElementScanner.swift` - walks the frontmost app's accessibility tree
  (bounded by depth/time/node-count limits) and produces a de-duplicated,
  quality-filtered list of `HintTarget`s (point, title, role, assigned label).
- `HackeyCoordinator.swift` - the central state machine: owns the current mode
  (idle/click/scroll), the search query, focus index, and dispatches every
  keystroke while a mode is active.
- `HotkeyMonitor.swift` - a blocking `CGEventTap` that captures (and can fully
  swallow) every keystroke while Hackey's mode is active, so label/query
  keystrokes never leak through to the underlying app's own shortcuts.
- `InteractionPerformer.swift` - executes the actual click/scroll as a genuine
  synthetic mouse event (`CGEvent`, never `AXUIElementPerformAction`) at the
  target's live (re-queried) screen coordinate, matching how a human would
  physically click.
- `OverlayManager.swift` - draws the badge overlay windows (one per screen).
- `SettingsStore.swift` - loads/saves `settings.json`.
- `AppDelegate.swift` - menu bar item and app lifecycle.

## Known limitations

- **Overlapping badges**: when two clickable elements sit only a few pixels
  apart (common in dense toolbars), their badges can visually overlap, making
  it easy to mistake one for the other. If a click seems to hit the wrong
  thing, zoom into a screenshot of the overlay to check for a second badge
  nearby before assuming a bug.
- Accessibility coverage varies by app/framework (Electron apps in particular
  can under-report clickable elements depending on their own AX
  implementation).
- No in-app GUI for remapping shortcuts yet - edit `settings.json` by hand.

## Publishing / updating this repo on GitHub (no `git` commands)

This project's own build folder (`.build`) must never be uploaded - it's just
compiled output that `swift build` regenerates every time, and it's already
listed in `.gitignore` for that reason. Only the items below need to go into
the GitHub repo:

```
.gitignore
.vscode/          (optional - only needed if you want the VS Code build task)
Package.swift
README.md
Sources/
Tests/
```

Do **not** upload the local `references/` folder - see
[References](#references) below for why.

### Uploading via GitHub's website (drag and drop)

1. Go to your repo on github.com → **Add file → Upload files**.
2. `.gitignore` and `.vscode` start with a dot, so Finder hides them by
   default. To reveal them: open Finder, go to this project folder, and press
   `Cmd+Shift+.` - dot files/folders appear slightly faded but are fully
   normal, draggable items.
   - If `.gitignore` still won't drag into the browser, duplicate it, rename
     the copy to `gitignore.txt` (no leading dot), drag that in instead, then
     in GitHub's web file editor rename it back to `.gitignore` (GitHub lets
     you rename any uploaded file, including adding a leading dot).
   - Same trick for the `.vscode` folder: duplicate it, rename the copy to
     `vscode` (no leading dot), drag that folder in - it'll upload as
     `vscode/tasks.json`. Then on github.com open `vscode/tasks.json`, click
     the pencil (edit), and use "Rename" to change its path to
     `.vscode/tasks.json`. GitHub creates the `.vscode` folder automatically
     the moment you add the leading dot, and VS Code will then recognize it
     correctly (as a `.vscode` config folder) whenever the repo is opened.
3. Drag in: `Sources`, `Tests`, `.gitignore`, `Package.swift`, `README.md`,
   and `.vscode`/`vscode` (if wanted) - all at once, straight from this
   project folder.
4. Scroll down, add a commit message, click **Commit changes**.

### Updating the repo later

Since this workflow doesn't use local `git`, the simplest way to push a
change (e.g. an edited `.swift` file or this README) is: open that same file
on github.com, click the pencil/edit icon, paste in the new content, and
commit. For multiple changed files, repeat the **Add file → Upload files**
drag-and-drop step - GitHub will overwrite any existing file with the same
path.

## References

Hackey was inspired by these existing keyboard-navigation tools (not
included in this repo - linked here instead of vendoring their code):

- [vimac](https://github.com/nchudleigh/vimac) - Vimium-style keyboard hint
  navigation for macOS.
- [homerow](https://github.com/nchudleigh/homerow) - keyboard-driven
  clicking/scrolling for macOS, by the same author.

## Notes

This project is for local personal use and has no license key, payment, or
telemetry logic.
