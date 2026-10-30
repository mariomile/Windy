import SwiftUI
import WindyCore

struct SettingsView: View {
    var onLayoutChange: () -> Void
    var onShortcutsChange: () -> Void
    var showTour: () -> Void

    var body: some View {
        TabView {
            GeneralSettings(showTour: showTour).tabItem { Label("General", systemImage: "gearshape") }
            LayoutSettings(onChange: onLayoutChange).tabItem { Label("Layout", systemImage: "rectangle.split.2x2") }
            HighlightSettings(onChange: onLayoutChange).tabItem { Label("Highlight", systemImage: "square.dashed") }
            AppsSettings(onChange: onLayoutChange).tabItem { Label("Apps", systemImage: "app.badge") }
            KeyboardSettings(onChange: onShortcutsChange).tabItem { Label("Keyboard", systemImage: "keyboard") }
            AgentSettings().tabItem { Label("Agents", systemImage: "terminal") }
        }
        .frame(width: 520, height: 440)
    }
}

private struct GeneralSettings: View {
    @Bindable var prefs = Prefs.shared
    var showTour: () -> Void

    var body: some View {
        Form {
            Toggle("Open at login", isOn: $prefs.openAtLogin)
            Picker("Appearance", selection: $prefs.appearance) {
                ForEach(Appearance.allCases) { Text($0.title).tag($0) }
            }
            Picker("Clean Space background", selection: $prefs.cleanBackground) {
                ForEach(CleanBackground.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Activate windows on hover", isOn: $prefs.focusFollowsMouse)
            LabeledContent("Welcome tour") { Button("Open Tour", action: showTour) }
        }
        .formStyle(.grouped)
    }
}

private struct LayoutSettings: View {
    @Bindable var prefs = Prefs.shared
    var onChange: () -> Void

    var body: some View {
        Form {
            Picker("Layout for new screens", selection: $prefs.defaultLayout) {
                ForEach(LayoutKind.allCases) { Text($0.title).tag($0) }
            }
            Picker("Windows per screen", selection: $prefs.defaultCount) {
                ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("Main window size", selection: $prefs.mainSize) {
                ForEach(MainSize.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("Space between windows") {
                HStack {
                    Slider(value: $prefs.gap, in: 0...24, step: 1)
                    Text("\(Int(prefs.gap)) pt").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }
            Toggle("Stack when the screen is full", isOn: $prefs.stackWhenFull)
            Text("When off, windows that don't fit float in the middle of the screen.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Apps that won't get small") {
                Button("Forget \(prefs.minSizes.count) learned sizes") {
                    prefs.minSizes = [:]
                    onChange()
                }
                .disabled(prefs.minSizes.isEmpty)
            }
        }
        .formStyle(.grouped)
        .onChange(of: prefs.mainSize) { onChange() }
        .onChange(of: prefs.gap) { onChange() }
        .onChange(of: prefs.defaultLayout) { onChange() }
        .onChange(of: prefs.defaultCount) { onChange() }
    }
}

private struct HighlightSettings: View {
    @Bindable var prefs = Prefs.shared
    var onChange: () -> Void
    private let swatches: [NSColor] = [
        NSColor(hex: "#4F7CFF")!, NSColor(hex: "#9B5CFF")!, NSColor(hex: "#FF5C93")!,
        NSColor(hex: "#FF9F1C")!, NSColor(hex: "#2BB673")!, NSColor(hex: "#8E8E93")!,
    ]

    var body: some View {
        Form {
            Picker("Highlight", selection: $prefs.highlight) {
                ForEach(Highlight.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("Color") {
                HStack(spacing: 8) {
                    ForEach(swatches, id: \.hex) { color in
                        Circle().fill(Color(nsColor: color)).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(.primary, lineWidth: prefs.highlightColor.hex == color.hex ? 2 : 0))
                            .onTapGesture { prefs.highlightColor = color }
                    }
                    ColorPicker("", selection: Binding(
                        get: { Color(nsColor: prefs.highlightColor) },
                        set: { prefs.highlightColor = NSColor($0) }
                    ), supportsOpacity: false).labelsHidden()
                }
            }
            LabeledContent("Border width") {
                Slider(value: $prefs.borderWidth, in: 1...8, step: 0.5)
            }
            LabeledContent("Corner radius") {
                Slider(value: $prefs.cornerRadius, in: 0...26, step: 1)
            }
            Section("No peek") {
                LabeledContent("Dim amount") {
                    Slider(value: $prefs.noPeekDim, in: 0.1...0.9)
                }
                Toggle("Blur other windows", isOn: $prefs.noPeekBlur)
            }
        }
        .formStyle(.grouped)
        .onChange(of: prefs.highlight) { onChange() }
    }
}

private struct AppsSettings: View {
    @Bindable var prefs = Prefs.shared
    var onChange: () -> Void
    @State private var running: [NSRunningApplication] = []

    var body: some View {
        Form {
            Section("Never tiled") {
                if prefs.excludedApps.isEmpty {
                    Text("Every app is tiled. Dialogs, sheets and panels never are.").foregroundStyle(.secondary)
                }
                ForEach(prefs.excludedApps, id: \.self) { bundle in
                    HStack {
                        Text(appName(bundle))
                        Spacer()
                        Button("Tile again") { prefs.setExcluded(bundle, false); onChange() }
                    }
                }
            }
            Section("Running apps") {
                ForEach(running, id: \.processIdentifier) { app in
                    if let bundle = app.bundleIdentifier {
                        Toggle(isOn: Binding(
                            get: { !prefs.isExcluded(bundle) },
                            set: { prefs.setExcluded(bundle, !$0); onChange() }
                        )) {
                            HStack {
                                if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                                Text(app.localizedName ?? bundle)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            running = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
                .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        }
    }

    private func appName(_ bundle: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return bundle }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

private struct KeyboardSettings: View {
    @Bindable var prefs = Prefs.shared
    var onChange: () -> Void

    var body: some View {
        Form {
            Picker("Shortcut prefix", selection: $prefs.prefix) {
                ForEach(ShortcutPrefix.allCases) { Text($0.symbols).tag($0) }
            }
            Section("Shortcuts") {
                ForEach(Shortcuts.all) { s in
                    row(s.title, Shortcuts.label(s, prefs.prefix))
                }
                row("Windows on this screen", prefs.prefix.symbols + Keys.countModifier(prefs.prefix).symbol + "1–5")
                row("Tab View", "⌥⇥")
                row("Swap with the mouse", "⌘-drag")
                row("Add to a stack with the mouse", "⌥⌘-drag")
            }
        }
        .formStyle(.grouped)
        .onChange(of: prefs.prefix) { onChange() }
    }

    private func row(_ title: String, _ keys: String) -> some View {
        LabeledContent(title) { Text(keys).font(.body.monospaced()).foregroundStyle(.secondary) }
    }
}

/// Puts a `windy` link to this app's binary on the PATH.
enum CLIInstall {
    static var binary: String { Bundle.main.executablePath ?? "/Applications/Windy.app/Contents/MacOS/Windy" }

    private static var folders: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/bin"]
    }

    static var installedPath: String? {
        folders.map { $0 + "/windy" }.first { (try? FileManager.default.destinationOfSymbolicLink(atPath: $0)) != nil }
    }

    /// Returns what happened, for the Settings window.
    static func install() -> String {
        let fm = FileManager.default
        for folder in folders where fm.isWritableFile(atPath: folder) {
            let link = folder + "/windy"
            if (try? fm.destinationOfSymbolicLink(atPath: link)) != nil { try? fm.removeItem(atPath: link) }
            guard !fm.fileExists(atPath: link) else { continue }
            if (try? fm.createSymbolicLink(atPath: link, withDestinationPath: binary)) != nil {
                return "Installed: \(link)"
            }
        }
        return "No writable folder on your PATH. Run in Terminal: sudo ln -sf \"\(binary)\" /usr/local/bin/windy"
    }
}

private struct AgentSettings: View {
    @Bindable var prefs = Prefs.shared
    @State private var installed = CLIInstall.installedPath
    @State private var message: String?

    private var mcpCommand: String {
        "claude mcp add windy -- \"\(installed.map { _ in "windy" } ?? CLIInstall.binary)\" mcp"
    }

    var body: some View {
        Form {
            Section("Command line") {
                Text("The windy command arranges windows from the terminal, from scripts, and from agents like Claude Code. Run windy help to see everything it does.")
                    .foregroundStyle(.secondary)
                Toggle("Allow the windy command and agents", isOn: $prefs.agentAccess)
                Text("When on, programs you run can list your windows with their titles, move them and open workspaces through Windy.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("windy command") {
                    if let installed {
                        Text(installed).font(.body.monospaced()).foregroundStyle(.secondary)
                    } else {
                        Button("Install") {
                            prefs.agentAccess = true
                            message = CLIInstall.install()
                            installed = CLIInstall.installedPath
                        }
                    }
                }
                if let message { Text(message).font(.caption).textSelection(.enabled) }
            }
            Section("MCP server") {
                Text("Let Claude see your screens and arrange windows while it works. Add Windy to Claude Code with:")
                    .foregroundStyle(.secondary)
                HStack {
                    Text(mcpCommand).font(.callout.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(mcpCommand, forType: .string)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
