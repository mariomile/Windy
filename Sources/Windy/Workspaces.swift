import AppKit
import Observation
import WindyCore

/// Finds an installed app by name or bundle identifier.
enum AppFinder {
    struct Found {
        let bundleID: String
        let url: URL
    }

    static func find(_ name: String) -> Found? {
        let workspace = NSWorkspace.shared
        if name.contains("."), let url = workspace.urlForApplication(withBundleIdentifier: name) {
            return Found(bundleID: name, url: url)
        }
        if let app = workspace.runningApplications.first(where: { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }),
           let id = app.bundleIdentifier, let url = app.bundleURL {
            return Found(bundleID: id, url: url)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                       "/System/Applications/Utilities", "\(home)/Applications"]
        for folder in folders {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            if let match = items.first(where: { $0.caseInsensitiveCompare("\(name).app") == .orderedSame }) {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(match)
                if let id = Bundle(url: url)?.bundleIdentifier { return Found(bundleID: id, url: url) }
            }
        }
        return nil
    }
}

struct CommandError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Saved setups, kept in ~/Library/Application Support/Windy/workspaces.json.
@MainActor @Observable
final class Workspaces {
    private(set) var all: [Workspace] = []
    @ObservationIgnored private let tiler: Tiler

    init(tiler: Tiler) {
        self.tiler = tiler
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: Paths.workspaces),
              let list = try? JSONDecoder().decode([Workspace].self, from: data) else { return }
        all = list
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(all) { try? data.write(to: Paths.workspaces, options: .atomic) }
    }

    func find(_ name: String) -> Workspace? {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Adds a workspace, replacing one with the same name.
    func define(_ workspace: Workspace) throws {
        let name = workspace.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw CommandError("A workspace needs a name.") }
        guard !workspace.screens.isEmpty, workspace.screens.allSatisfy({ !$0.apps.isEmpty }) else {
            throw CommandError("Each screen in a workspace needs at least one app.")
        }
        all.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        var copy = workspace
        copy.name = name
        all.append(copy)
        persist()
    }

    func delete(_ name: String) throws {
        guard find(name) != nil else { throw CommandError("No workspace named \"\(name)\".") }
        all.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        persist()
    }

    /// Saves what's tiled now: each screen's layout and its apps in tile order.
    @discardableResult
    func saveCurrent(_ name: String, screen only: Int? = nil) throws -> Workspace {
        var screens: [WorkspaceScreen] = []
        for (i, screen) in NSScreen.screens.enumerated() where only == nil || only == i + 1 {
            guard let tiles = tiler.tiles(onDisplay: screen.uuid), !tiles.tiles.isEmpty else { continue }
            let apps = tiles.tiles.compactMap { tile in
                tiler.tracker.windows[tile.top].map { WorkspaceApp(app: $0.bundleID ?? $0.appName) }
            }
            let layout = tiler.prefs.layout(for: screen.uuid)
            screens.append(WorkspaceScreen(screen: NSScreen.screens.count > 1 ? i + 1 : nil,
                                           layout: layout.kind, count: layout.count, apps: apps))
        }
        guard !screens.isEmpty else { throw CommandError("There are no tiled windows to save.") }
        let workspace = Workspace(name: name, screens: screens)
        try define(workspace)
        return workspace
    }

    /// Opens every app in a workspace, waits for their windows and lays them out.
    func open(_ name: String, completion: @escaping (JSON) -> Void) throws {
        guard let workspace = find(name) else { throw CommandError("No workspace named \"\(name)\".") }
        guard tiler.isActive else { throw CommandError("Tiling is off, so Windy can't lay out a workspace.") }

        struct Entry {
            let screen: Int
            let request: String
            let found: AppFinder.Found?
            let existing: Set<WindowID>
            /// Something to look for in the window title: the folder or host the entry opened.
            let hint: String?
            let deadline: Date
            var window: WindowID?
        }

        let now = Date()
        var entries: [Entry] = []
        for (s, spec) in workspace.screens.enumerated() {
            for item in spec.apps {
                let found = AppFinder.find(item.app)
                let runningApp = found.flatMap { f in NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == f.bundleID } }
                let running = runningApp != nil
                // Hidden apps and minimized windows come back so they can be placed.
                var wait: TimeInterval = 0
                if let runningApp, runningApp.isHidden {
                    runningApp.unhide()
                    wait = 1.5
                }
                for w in tiler.tracker.windows.values where w.bundleID == found?.bundleID && w.minimized {
                    w.element.set(kAXMinimizedAttribute, false as CFBoolean)
                    wait = 1.5
                }
                let existing = Set(tiler.tracker.windows.values.filter { $0.bundleID == found?.bundleID }.map(\.id))
                var hint: String?
                if let target = item.open {
                    hint = target.contains("://") ? URL(string: target)?.host : URL(fileURLWithPath: (target as NSString).expandingTildeInPath).lastPathComponent
                }
                if let found {
                    let config = NSWorkspace.OpenConfiguration()
                    if let target = item.open {
                        let url = target.contains("://") ? URL(string: target)
                            : URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
                        if let url { NSWorkspace.shared.open([url], withApplicationAt: found.url, configuration: config) }
                        wait = running ? 3 : 12
                    } else if !running || existing.isEmpty {
                        NSWorkspace.shared.openApplication(at: found.url, configuration: config)
                        wait = running ? 3 : 12
                    }
                }
                entries.append(Entry(screen: s, request: item.app, found: found, existing: existing, hint: hint,
                                     deadline: now.addingTimeInterval(wait)))
            }
        }

        // Match each entry to a window: a new one if the entry opened something, else any free one.
        func match() -> Bool {
            let visible = tiler.tracker.visibleWindows()
            var claimed = Set(entries.compactMap(\.window))
            var done = true
            for i in entries.indices where entries[i].window == nil {
                guard let bundle = entries[i].found?.bundleID else { continue }
                let candidates = visible.filter { $0.bundleID == bundle && !claimed.contains($0.id) }
                let fresh = candidates.filter { !entries[i].existing.contains($0.id) }
                let late = Date() >= entries[i].deadline
                // With several entries for one app, each waits for the window showing what it opened.
                let shared = entries.filter { $0.found?.bundleID == bundle }.count > 1
                let titled = entries[i].hint.flatMap { hint in fresh.first { $0.title.localizedCaseInsensitiveContains(hint) } }
                let pick = titled ?? ((shared && entries[i].hint != nil && !late) ? nil : fresh.first) ?? (late ? candidates.first : nil)
                if let pick {
                    entries[i].window = pick.id
                    claimed.insert(pick.id)
                } else if Date() < entries[i].deadline {
                    done = false
                }
            }
            return done
        }

        func finish() {
            // Splash and updater windows can close before the real one appears: match those again.
            let open = Set(tiler.tracker.visibleWindows().map(\.id))
            for i in entries.indices where entries[i].window.map({ !open.contains($0) }) == true { entries[i].window = nil }
            _ = match()
            var placed: [String] = []
            var missing: [String] = entries.filter { $0.found == nil }.map { "\($0.request) (not installed)" }
            for (s, spec) in workspace.screens.enumerated() {
                let screens = NSScreen.screens
                let screen = spec.screen.flatMap { $0 >= 1 && $0 <= screens.count ? screens[$0 - 1] : nil } ?? NSScreen.main ?? screens[0]
                let mine = entries.filter { $0.screen == s }
                let ids = mine.compactMap(\.window)
                missing += mine.filter { $0.found != nil && $0.window == nil }.map { "\($0.request) (no window)" }
                guard !ids.isEmpty else { continue }
                let left = tiler.arrange(ids, on: screen.uuid, kind: spec.layout, count: spec.count ?? ids.count)
                placed += mine.filter { $0.window.map { !left.contains($0) } ?? false }.map(\.request)
            }
            completion(["ok": true, "result": ["workspace": workspace.name, "placed": placed, "missing": missing]])
        }

        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { timer in
            MainActor.assumeIsolated {
                if match() || entries.allSatisfy({ Date() >= $0.deadline }) {
                    _ = match()
                    timer.invalidate()
                    finish()
                }
            }
        }
    }
}
