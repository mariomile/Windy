import AppKit
import WindyCore

/// Answers `windy` and MCP requests inside the app. Every request is `{"command": ..., "args": {...}}`;
/// every reply is `{"ok": true, "result": ...}` or `{"ok": false, "error": "..."}`.
@MainActor
final class Commands {
    private let tiler: Tiler
    private let workspaces: Workspaces
    private var prefs: Prefs { tiler.prefs }
    private var tracker: WindowTracker { tiler.tracker }

    init(tiler: Tiler, workspaces: Workspaces) {
        self.tiler = tiler
        self.workspaces = workspaces
    }

    func handle(_ request: JSON, reply: @escaping (JSON) -> Void) {
        let command = request["command"] as? String ?? ""
        let args = request["args"] as? JSON ?? [:]
        // Windy can see and move every window. Other programs only get that through it once you say so.
        guard prefs.agentAccess else {
            reply(["ok": false, "error": "The windy command is off. Turn it on in Windy › Settings › Agents."])
            return
        }
        do {
            switch command {
            case "status": reply(ok(status()))
            case "windows": reply(ok(windows()))
            case "layout": reply(ok(try layout(args)))
            case "arrange": reply(ok(try arrange(args)))
            case "focus": reply(ok(try focus(args)))
            case "swap": reply(ok(try swap(args)))
            case "primary": reply(ok(try primary(args)))
            case "toggle": reply(ok(try toggle(args)))
            case "float": reply(ok(try float(args)))
            case "workspace.list": reply(ok(["workspaces": workspaces.all.map(encode)]))
            case "workspace.show": reply(ok(encode(try workspace(named: try string(args, "name")))))
            case "workspace.save":
                let saved = try workspaces.saveCurrent(try string(args, "name"), screen: args["screen"] as? Int)
                reply(ok(["saved": encode(saved)]))
            case "workspace.define":
                let data = try JSONSerialization.data(withJSONObject: args)
                guard let ws = try? JSONDecoder().decode(Workspace.self, from: data) else {
                    throw CommandError("A workspace is {\"name\": ..., \"screens\": [{\"layout\": ..., \"apps\": [{\"app\": ..., \"open\": ...}]}]}.")
                }
                try workspaces.define(ws)
                reply(ok(["saved": encode(ws)]))
            case "workspace.delete":
                try workspaces.delete(try string(args, "name"))
                reply(ok(["deleted": args["name"] ?? ""]))
            case "workspace.open":
                try workspaces.open(try string(args, "name"), completion: reply)
            default:
                throw CommandError("Unknown command \"\(command)\".")
            }
        } catch let error as CommandError {
            reply(["ok": false, "error": error.message])
        } catch {
            reply(["ok": false, "error": error.localizedDescription])
        }
    }

    private func ok(_ result: Any) -> JSON { ["ok": true, "result": result] }

    // MARK: Reading

    private var state: String {
        if !Accessibility.isTrusted { return "needs-accessibility" }
        if !prefs.setupDone { return "needs-setup" }
        if !prefs.tilingEnabled { return "off" }
        if tiler.stageManagerOn { return "paused-for-stage-manager" }
        return "tiling"
    }

    private func requireTiling() throws {
        guard tiler.isActive else {
            switch state {
            case "needs-accessibility": throw CommandError("Windy needs Accessibility access. Open Windy from the menu bar to grant it.")
            case "needs-setup": throw CommandError("Windy's setup isn't finished. Open Windy from the menu bar to finish it.")
            case "off": throw CommandError("Tiling is off. Turn it on with `windy tiling on`.")
            default: throw CommandError("Windy is paused while Stage Manager is on.")
            }
        }
    }

    private func describe(_ id: WindowID) -> JSON {
        guard let w = tracker.windows[id] else { return ["id": id] }
        return ["id": id, "app": w.appName, "bundle": w.bundleID ?? "", "title": w.title]
    }

    private func status() -> JSON {
        let screens = NSScreen.screens.enumerated().map { i, screen -> JSON in
            let layout = prefs.layout(for: screen.uuid)
            let tiles = tiler.tiles(onDisplay: screen.uuid)
            return [
                "screen": i + 1,
                "name": screen.localizedName,
                "main": screen == NSScreen.main,
                "layout": layout.kind.rawValue,
                "count": layout.count,
                "maxCount": Layout.capacity(layout.kind, shape: screen.shape),
                "zoomed": tiles?.zoomed.map(describe) ?? NSNull(),
                "tiles": (tiles?.tiles ?? []).enumerated().map { j, tile -> JSON in
                    ["tile": j + 1, "showing": describe(tile.top),
                     "stacked": tile.stack.filter { $0 != tile.top }.map(describe)]
                },
            ]
        }
        return [
            "state": state,
            "focused": tiler.focused.map(describe) ?? NSNull(),
            "screens": screens,
            "floating": tiler.floating.sorted().map(describe),
            "noPeek": tiler.noPeek,
            "cleanSpace": tiler.cleanSpace.map { describe($0.window) } ?? NSNull(),
        ]
    }

    private func windows() -> [JSON] {
        let order = Dictionary(uniqueKeysWithValues: tiler.mru.enumerated().map { ($1, $0) })
        return tracker.switchableWindows()
            .sorted { (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max) }
            .map { w in
                var out = describe(w.id)
                if let frame = w.element.frame,
                   let i = NSScreen.screens.firstIndex(where: { $0 == NSScreen.containing(axPoint: CGPoint(x: frame.midX, y: frame.midY)) }) {
                    out["screen"] = i + 1
                }
                if let (display, tile) = tiler.locate(w.id) {
                    out["tile"] = tile + 1
                    out["showing"] = tiler.tiles(onDisplay: display)?.tiles[tile].top == w.id
                }
                out["floating"] = tiler.floating.contains(w.id)
                out["minimized"] = w.minimized
                out["excluded"] = prefs.isExcluded(w.bundleID)
                out["focused"] = tiler.focused == w.id
                return out
            }
    }

    // MARK: Arguments

    private func string(_ args: JSON, _ key: String) throws -> String {
        guard let value = args[key] as? String, !value.isEmpty else { throw CommandError("Missing \"\(key)\".") }
        return value
    }

    private func screen(_ args: JSON) throws -> String {
        if let n = args["screen"] as? Int {
            let screens = NSScreen.screens
            guard n >= 1, n <= screens.count else { throw CommandError("There's no screen \(n). Screens are 1 to \(screens.count).") }
            return screens[n - 1].uuid
        }
        guard let uuid = tiler.currentScreenUUID else { throw CommandError("No screen found.") }
        return uuid
    }

    private func layoutKind(_ args: JSON) throws -> LayoutKind? {
        guard let raw = args["layout"] as? String else { return nil }
        guard let kind = LayoutKind(rawValue: raw.lowercased()) else {
            throw CommandError("Layouts are grid, columns, rows and side.")
        }
        return kind
    }

    /// A window by ID, app name, bundle ID, title text, or "App: title text".
    /// Most recently used windows win ties; `except` skips windows already picked.
    func resolve(_ ref: String, except: Set<WindowID> = []) -> WindowID? {
        let rank = Dictionary(uniqueKeysWithValues: tiler.mru.enumerated().map { ($1, $0) })
        let candidates = tracker.switchableWindows()
            .filter { !except.contains($0.id) }
            .sorted { ($0.minimized ? 1 : 0, rank[$0.id] ?? Int.max) < ($1.minimized ? 1 : 0, rank[$1.id] ?? Int.max) }
        if let n = WindowID(ref), candidates.contains(where: { $0.id == n }) { return n }

        let query = ref.trimmingCharacters(in: .whitespaces)
        var pool = candidates
        var titlePart: String?
        if let colon = query.firstIndex(of: ":") {
            let app = query[..<colon].trimmingCharacters(in: .whitespaces)
            let narrowed = candidates.filter { $0.appName.caseInsensitiveCompare(app) == .orderedSame || $0.bundleID == app }
            if !narrowed.isEmpty {
                pool = narrowed
                titlePart = query[query.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        if let titlePart {
            return (pool.first { $0.title.localizedCaseInsensitiveContains(titlePart) } ?? pool.first)?.id
        }
        let checks: [(TrackedWindow) -> Bool] = [
            { $0.appName.caseInsensitiveCompare(query) == .orderedSame },
            { $0.bundleID?.caseInsensitiveCompare(query) == .orderedSame },
            { $0.appName.localizedCaseInsensitiveContains(query) },
            { $0.title.localizedCaseInsensitiveContains(query) },
        ]
        for check in checks { if let hit = pool.first(where: check) { return hit.id } }
        return nil
    }

    private func window(_ args: JSON, required: Bool = false) throws -> WindowID? {
        guard let ref = args["window"].map({ "\($0)" }), !ref.isEmpty else {
            if required { throw CommandError("Missing \"window\".") }
            return nil
        }
        guard let id = resolve(ref) else { throw CommandError("No window matches \"\(ref)\". `windy windows` lists them.") }
        return id
    }

    // MARK: Acting

    private func layout(_ args: JSON) throws -> JSON {
        try requireTiling()
        let display = try screen(args)
        let kind = try layoutKind(args)
        let count = args["count"] as? Int
        if let count, !(1...5).contains(count) { throw CommandError("Count goes from 1 to 5.") }
        guard kind != nil || count != nil else { throw CommandError("Give a layout, a count, or both.") }
        tiler.setLayout(kind: kind, count: count, screen: display)
        let now = prefs.layout(for: display)
        return ["layout": now.kind.rawValue, "count": now.count]
    }

    private func arrange(_ args: JSON) throws -> JSON {
        try requireTiling()
        guard let refs = args["windows"] as? [Any], !refs.isEmpty else { throw CommandError("List the windows to arrange.") }
        let display = try screen(args)
        var ids: [WindowID] = []
        var unknown: [String] = []
        for ref in refs.map({ "\($0)" }) {
            if let id = resolve(ref, except: Set(ids)) { ids.append(id) } else { unknown.append(ref) }
        }
        guard !ids.isEmpty else { throw CommandError("No window matches \(unknown.joined(separator: ", ")).") }
        let left = tiler.arrange(ids, on: display, kind: try layoutKind(args), count: args["count"] as? Int)
        return [
            "arranged": ids.filter { !left.contains($0) }.map(describe),
            "notTileable": left.map(describe),
            "unknown": unknown,
        ]
    }

    private func focus(_ args: JSON) throws -> JSON {
        guard let id = try window(args, required: true) else { return [:] }
        tiler.focus(id)
        return ["focused": describe(id)]
    }

    private func swap(_ args: JSON) throws -> JSON {
        try requireTiling()
        let raw = try string(args, "direction")
        let directions: [String: Direction] = ["left": .left, "right": .right, "up": .up, "down": .down]
        guard let direction = directions[raw.lowercased()] else { throw CommandError("Directions are left, right, up and down.") }
        let id = try window(args) ?? tiler.focused
        guard let id, tiler.locate(id) != nil else { throw CommandError("That window isn't tiled.") }
        tiler.swap(direction, window: id)
        return ["moved": describe(id)]
    }

    private func primary(_ args: JSON) throws -> JSON {
        try requireTiling()
        let id = try window(args) ?? tiler.focused
        guard let id, tiler.locate(id) != nil else { throw CommandError("That window isn't tiled.") }
        tiler.makePrimary(id)
        return ["primary": describe(id)]
    }

    private func toggle(_ args: JSON) throws -> JSON {
        let mode = try string(args, "mode").lowercased().replacingOccurrences(of: "-", with: "_")
        let wanted = args["on"] as? Bool
        switch mode {
        case "tiling":
            prefs.tilingEnabled = wanted ?? !prefs.tilingEnabled
            tiler.reconcile()
            return ["tiling": prefs.tilingEnabled]
        case "no_peek", "nopeek":
            if wanted != tiler.noPeek { tiler.noPeek = wanted ?? !tiler.noPeek }
            return ["noPeek": tiler.noPeek]
        case "zoom", "focus":
            try requireTiling()
            let id = try window(args) ?? tiler.focused
            guard let id, let (display, _) = tiler.locate(id) else { throw CommandError("That window isn't tiled.") }
            let isOn = tiler.tiles(onDisplay: display)?.zoomed == id
            if wanted != isOn { tiler.toggleFocusMode(id) }
            return ["zoomed": tiler.tiles(onDisplay: display)?.zoomed == id]
        case "clean_space", "clean":
            try requireTiling()
            let isOn = tiler.cleanSpace != nil
            if wanted != isOn {
                if isOn { tiler.endCleanSpace() } else {
                    let id = try window(args) ?? tiler.focused
                    guard let id, tiler.locate(id) != nil else { throw CommandError("That window isn't tiled.") }
                    tiler.toggleCleanSpace(id)
                }
            }
            return ["cleanSpace": tiler.cleanSpace.map { describe($0.window) } ?? NSNull()]
        default:
            throw CommandError("Modes are tiling, zoom, clean_space and no_peek.")
        }
    }

    private func float(_ args: JSON) throws -> JSON {
        try requireTiling()
        guard let id = try window(args) ?? tiler.focused else { throw CommandError("No window to float.") }
        tiler.toggleFloat(id)
        return ["window": describe(id), "floating": tiler.floating.contains(id)]
    }

    // MARK: Workspaces

    private func workspace(named name: String) throws -> Workspace {
        guard let ws = workspaces.find(name) else { throw CommandError("No workspace named \"\(name)\".") }
        return ws
    }

    private func encode(_ workspace: Workspace) -> Any {
        guard let data = try? JSONEncoder().encode(workspace) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    }
}
