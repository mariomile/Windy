# Windy

Automatic window tiling for macOS. Open a window and Windy gives it a place. Close one and the rest fill the space. No dragging, no layouts to draw.

Free and open source, under the MIT license. Website: [mariomiletta.com/windy](https://www.mariomiletta.com/windy)

## What it does

- **Tiles every new window** the moment it opens, and reflows the rest when one closes.
- **Four layouts:** Grid (each new window takes half of the newest space, four make a 2×2 grid), Columns, Rows and Side. One to four windows per screen, five in Side on ultrawide and vertical monitors.
- **One layout per display.** Move a window past a screen edge and it goes to the next display.
- **Stacks:** when a screen is full, new windows stack in the tile you're using.
- **Focus mode** zooms one window to the whole screen and puts it back.
- **No peek** dims and blurs every window except the active one.
- **Clean Space** shows one window on a plain background, for screen sharing.
- **Tab View** (⌥⇥) switches windows, laid out screen by screen.
- Swap with the keyboard or ⌘-drag, resize by dragging the edge between two windows, highlight the active window, exclude apps, pause while Stage Manager is on.

## Install

1. Download [Windy.zip](https://www.mariomiletta.com/windy/Windy.zip), unzip it and drag Windy to Applications.
2. Open it. macOS says it can't check the developer, because the app isn't notarized yet. Go to System Settings › Privacy & Security and click **Open Anyway**.
3. Allow Accessibility when Windy asks. It's the only permission it needs.

Requires macOS 15 Sequoia or later.

## Build from source

Needs Xcode 16 or later.

```bash
./scripts/build-app.sh
```

This builds `build/Windy.app`, signs it ad hoc and zips it to `build/Windy.zip`. Set `SIGN_IDENTITY` to a Developer ID to sign for distribution.

Run the tests:

```bash
swift test
```

## Shortcuts

The prefix is ⌃⌥ by default; pick ⌥⌘ or ⌃⇧ in Settings › Keyboard.

| Shortcut | Action |
| --- | --- |
| ⌃⌥Z | Focus mode |
| ⌃⌥D | No peek |
| ⌃⌥P | Clean Space |
| ⌃⌥ ← → ↑ ↓ | Swap with the neighbor, or move to the next display |
| ⌃⌥↩ | Make the active window primary |
| ⌃⌥= / ⌃⌥- / ⌃⌥0 | Bigger, smaller, reset sizes |
| ⌃⌥] / ⌃⌥[ | Next or previous window |
| ⌃⌥` / ⌃⌥⇧` | Next or previous window in a stack |
| ⌃⌥F | Float or tile the active window |
| ⌃⌥⌘1–5 | Windows on this screen |
| ⌥⇥ | Tab View |

## Privacy

Windy uses Accessibility access to read and set window positions and sizes, and which app a window belongs to. It never reads window contents or keystrokes: its shortcuts are registered with macOS, which only reports Windy's own key combinations. Window titles are read only while Tab View is open, to label it. Nothing is saved or sent anywhere, and Windy works offline.

## How it's built

- `Sources/WindyCore`: the layout engine. Pure geometry, covered by tests.
- `Sources/Windy`: the app. Window tracking through Accessibility, the tiler, shortcuts, overlays, the menu bar panel and Settings.

## License

MIT. See [LICENSE](LICENSE).
