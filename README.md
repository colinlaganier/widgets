<h2 align="center">Desktop Widgets</h2>

Small AppKit/SwiftUI desktop widgets (Azure, Claude usage, GitHub,
Hacker News, W&B). Each lives in its own directory as a single `main.swift`
built into a standalone `.app` by its `build.sh`.

## Shared layout system

Window placement behaviour is shared, not per-widget: every `build.sh`
compiles `shared/WidgetChrome.swift` in alongside `main.swift`, and each
widget makes exactly two calls into it — `WidgetChrome.shared.adopt(window)`
at launch and `WidgetChromeMenu()` in its context menu. Change the shared
file, re-run each `build.sh`, and all widgets pick up the new behaviour.

### Snap into place

Drop a widget near the left (or right) screen edge, or near another widget,
and it clicks into alignment — left edges align, and it slots 16 pt above or
below its neighbour. Snapping animates and gives a haptic tick on trackpads.
Drop it well clear of any snap target and it stays exactly where you put it.

### Arrange in Left Column

Right-click any widget → **Arrange Widgets in Left Column**. The widget
broadcasts over `DistributedNotificationCenter`; every running widget moves
its own window into a single top-to-bottom column on the left edge of
whichever screen it's on (per-screen columns, current vertical order kept).

### Group drag handle

The bottom-most widget on each screen shows a small rounded pill centered
below itself. Drag the pill to move **all** widgets together — anywhere on
the desktop, including onto another display. Widgets keep their exact
relative positions during a group drag (individual snapping stays out of it).

Right-clicking the pill offers group actions:

- **Arrange Widgets in Left Column** — same as the per-widget menu item.
- **Gather All Widgets Here** — pulls every widget onto the desktop you're
  currently looking at (the pill itself is visible on every desktop, so this
  works even when the widgets are pinned to a different one). Each widget
  keeps its own pin mode.
- **Show Widgets on All Desktops** — toggles desktop pinning for the whole
  group at once.

The pill is hosted by whichever widget process owns the lowest window
(re-elected automatically as widgets move, launch, or quit), so there is no
sixth app to run.

### Desktops (Spaces)

Widgets appear on every desktop by default. Right-click →
**Show on All Desktops** to toggle; turning it off pins the widget to the
desktop you're currently on.

To move a pinned widget to a different desktop:

1. Right-click it → enable **Show on All Desktops**.
2. Switch to the target desktop.
3. Right-click it → disable **Show on All Desktops**. It stays there.

### How widgets find each other

Each widget is a separate process, so there's no shared in-memory state.
For snapping/arranging, a widget discovers its peers through
`CGWindowListCopyWindowInfo`, matching windows that share the widgets'
unusual window level (one above Finder's desktop icons) — window frames are
readable without any screen-recording permission. Cross-process commands
(arrange) go over `DistributedNotificationCenter`.

## Building

The interactive builder at the repo root builds any subset of the widgets:

```sh
./build.sh
```

Pick widgets from the checkbox list — ↑/↓ to move, space to toggle,
enter to build, esc to quit. After building it offers to add the built
apps to Login Items (via System Events) so they start automatically on
login; manage them later under System Settings → General → Login Items.

Non-interactive: `./build.sh --all` builds everything, and
`./build.sh --all --login` also registers the apps to start on login.

To build a single widget by hand:

```sh
cd <widget-dir> && ./build.sh && open <WidgetName>.app
```
