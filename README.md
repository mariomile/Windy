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
- **Remembers each Space:** every desktop keeps its own tiles, so switching away and back finds them as you left them.
- **Apps that won't get small:** Windy learns the smallest size an app accepts and moves the split lines to make room. If a screen can't fit them all, the newest one floats.
- **Workspaces:** save a setup (which apps, on which screen, in which order and layout) and open it again in one go. Apps launch, open their project folder or URL, and fall into place.
- **Agent-ready:** the `windy` command and a built-in MCP server let Claude and other agents see your screens and arrange windows while they work.
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

## The `windy` command

The app's own binary is also a command line tool. Install it from Settings › Agents, or link it yourself:

```bash
ln -sf /Applications/Windy.app/Contents/MacOS/Windy /usr/local/bin/windy
```

```bash
windy status                                  # screens, layouts and what's in each tile
windy windows                                 # every window with its ID
windy arrange Cursor "Safari: localhost" Ghostty --layout side
windy layout columns --count 3 --screen 2
windy zoom on
windy workspace save coding
windy workspace open coding
```

Windows can be named by ID, app name, bundle ID, part of the title, or `App: title text`. Add `--json` to any command for machine-readable output. If Windy isn't running, the command starts it. `windy help` lists everything.

### Workspaces

A workspace is JSON you can write by hand, or have an agent write:

```json
{
  "name": "coding",
  "screens": [
    {
      "layout": "side",
      "apps": [
        { "app": "Cursor", "open": "~/code/my-site" },
        { "app": "Safari", "open": "http://localhost:3000" },
        { "app": "Ghostty" }
      ]
    }
  ]
}
```

```bash
windy workspace define coding.json
```

Apps go in tile order: the first gets the primary tile. `screen` (1-based, as in `windy status`) picks a display; `count` sets how many windows tile there. Workspaces live in `~/Library/Application Support/Windy/workspaces.json`.

### MCP server

`windy mcp` runs a Model Context Protocol server over stdio. Add it to Claude Code:

```bash
claude mcp add windy -- windy mcp
```

Claude gets tools to read your screens and windows, set layouts, arrange windows in order, toggle focus mode, Clean Space and No peek, and open, save or define workspaces. Each call goes to the running app over a socket in your Library that only your user can open.

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

Windy uses Accessibility access to read and set window positions and sizes, and which app a window belongs to. It never reads window contents or keystrokes: its shortcuts are registered with macOS, which only reports Windy's own key combinations. Window titles are read only to label Tab View, and when you or an agent ask for them through the `windy` command, on your Mac. The command talks to the app through a local socket only your user can open. Nothing is sent anywhere, and Windy works offline. The only things saved are your settings, your workspaces and the minimum window size of apps that refused a smaller tile.

## How it's built

- `Sources/WindyCore`: the layout engine, tile and stack state, and the workspace format. Pure code, covered by tests.
- `Sources/Windy`: the app. Window tracking through Accessibility, the tiler, shortcuts, overlays, the menu bar panel and Settings, plus the `windy` command, its socket server and the MCP server.
- Spaces are read with the same private, read-only CoreGraphics calls other macOS window managers use. Nothing needs System Integrity Protection turned off.

## License

MIT. See [LICENSE](LICENSE).
