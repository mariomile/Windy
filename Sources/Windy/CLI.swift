import AppKit

/// The `windy` command. Same binary as the app: with arguments it talks to the running app
/// (starting it if needed) instead of launching the menu bar app.
enum CLI {
    static let usage = """
    windy: control Windy, the window tiler, from the terminal or an agent.

    Windows can be named by ID, app name ("Safari"), bundle ID, part of the title,
    or "App: title text". `windy windows` lists them.

      windy status                               Screens, layouts and what's in each tile
      windy windows                              Every window with its ID, app, screen and tile
      windy layout <grid|columns|rows|side> [--count N] [--screen N]
      windy count <1-5> [--screen N]             Windows that tile on a screen
      windy arrange <window>... [--layout L] [--count N] [--screen N]
                                                 First window becomes primary, the rest follow in order
      windy focus <window>
      windy swap <left|right|up|down> [--window W]
      windy primary [<window>]
      windy zoom [on|off] [--window W]           Focus mode
      windy clean [on|off] [--window W]          Clean Space
      windy nopeek [on|off]
      windy tiling <on|off>
      windy float [<window>]                     Float a tiled window, or tile a floating one
      windy workspace list
      windy workspace show <name>
      windy workspace open <name>
      windy workspace save <name> [--screen N]   Save what's tiled now
      windy workspace define <file.json | ->     Add a workspace from JSON (- reads stdin)
      windy workspace delete <name>
      windy mcp                                  Run as an MCP server over stdio

    Add --json to any command for machine-readable output.
    """

    /// Finder and Xcode launch apps with -psn_ or -NS... arguments; those still start the app.
    static func isCommand(_ arguments: [String]) -> Bool {
        guard arguments.count > 1 else { return false }
        let first = arguments[1]
        return !first.hasPrefix("-psn") && !first.hasPrefix("-NS") && !first.hasPrefix("-Apple")
    }

    static func run(_ arguments: [String]) -> Int32 {
        var words = Array(arguments.dropFirst())
        let json = words.contains("--json")
        words.removeAll { $0 == "--json" }
        guard let first = words.first else { return fail(usage) }

        switch first {
        case "help", "-h", "--help":
            print(usage)
            return 0
        case "mcp":
            return MCP.run()
        default:
            let request: JSON
            do { request = try parse(words) } catch let error as CommandError { return fail(error.message + "\n\n" + usage) } catch {
                return fail(error.localizedDescription)
            }
            guard let reply = send(request) else {
                return fail("Couldn't reach Windy. Is it installed in Applications?")
            }
            guard reply["ok"] as? Bool == true else {
                return fail((reply["error"] as? String) ?? "Windy couldn't do that.")
            }
            let result = reply["result"] ?? [:]
            if json { printJSON(result) } else { printHuman(request["command"] as? String ?? "", result) }
            return 0
        }
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 1
    }

    // MARK: Parsing

    private static func parse(_ words: [String]) throws -> JSON {
        var positional: [String] = []
        var options: JSON = [:]
        var i = 1
        while i < words.count {
            let word = words[i]
            if word.hasPrefix("--") {
                let key = String(word.dropFirst(2))
                guard i + 1 < words.count else { throw CommandError("\(word) needs a value.") }
                let value = words[i + 1]
                switch key {
                case "count", "screen":
                    guard let n = Int(value) else { throw CommandError("\(word) takes a number.") }
                    options[key] = n
                case "layout", "window":
                    options[key] = value
                default:
                    throw CommandError("Unknown option \(word).")
                }
                i += 2
            } else {
                positional.append(word)
                i += 1
            }
        }

        func onOff(_ word: String?) throws -> Bool? {
            switch word {
            case nil: return nil
            case "on": return true
            case "off": return false
            default: throw CommandError("Use on or off.")
            }
        }
        func need(_ n: Int, _ what: String) throws {
            guard positional.count >= n else { throw CommandError("Missing \(what).") }
        }

        var args = options
        let command: String
        switch words[0] {
        case "status", "windows":
            command = words[0]
        case "layout":
            command = "layout"
            if let kind = positional.first { args["layout"] = kind }
        case "count":
            try need(1, "the number of windows")
            guard let n = Int(positional[0]) else { throw CommandError("count takes a number.") }
            command = "layout"
            args["count"] = n
        case "arrange":
            try need(1, "the windows to arrange")
            command = "arrange"
            args["windows"] = positional
        case "focus":
            try need(1, "the window to focus")
            command = "focus"
            args["window"] = positional[0]
        case "swap":
            try need(1, "a direction")
            command = "swap"
            args["direction"] = positional[0]
        case "primary":
            command = "primary"
            if let w = positional.first { args["window"] = w }
        case "zoom", "clean", "nopeek", "tiling":
            command = "toggle"
            args["mode"] = ["zoom": "zoom", "clean": "clean_space", "nopeek": "no_peek", "tiling": "tiling"][words[0]]!
            if let on = try onOff(positional.first) { args["on"] = on }
            if words[0] == "tiling", positional.isEmpty { throw CommandError("Use windy tiling on or windy tiling off.") }
        case "float":
            command = "float"
            if let w = positional.first { args["window"] = w }
        case "workspace", "workspaces":
            let sub = positional.first ?? "list"
            switch sub {
            case "list":
                command = "workspace.list"
            case "show", "open", "delete", "save":
                try need(2, "the workspace name")
                command = "workspace.\(sub)"
                args["name"] = positional[1...].joined(separator: " ")
            case "define":
                try need(2, "a JSON file, or - for stdin")
                let data = positional[1] == "-" ? FileHandle.standardInput.readDataToEndOfFile()
                    : (try? Data(contentsOf: URL(fileURLWithPath: (positional[1] as NSString).expandingTildeInPath))) ?? Data()
                guard let object = (try? JSONSerialization.jsonObject(with: data)) as? JSON else {
                    throw CommandError("That isn't a workspace JSON object.")
                }
                command = "workspace.define"
                args = object
            default:
                throw CommandError("Unknown workspace command \"\(sub)\".")
            }
        default:
            throw CommandError("Unknown command \"\(words[0])\".")
        }
        return ["command": command, "args": args]
    }

    // MARK: Talking to the app

    /// Sends one request, starting Windy in the background if it isn't running.
    static func send(_ request: JSON) -> JSON? {
        var fd = Socket.connect(Paths.socket)
        if fd == nil {
            launchApp()
            let deadline = Date().addingTimeInterval(10)
            while fd == nil, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.2)
                fd = Socket.connect(Paths.socket)
            }
        }
        guard let fd else { return nil }
        defer { close(fd) }
        Socket.write(fd, request)
        guard let line = Socket.readLine(fd) else { return nil }
        return (try? JSONSerialization.jsonObject(with: line)) as? JSON
    }

    private static func launchApp() {
        // The app this binary lives in (also when called through a symlink), else the installed one.
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundle = binary.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = bundle.pathExtension == "app" ? bundle
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: "app.windy.mac")
        guard let app else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", app.path]
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: Output

    static func printJSON(_ object: Any) {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object, options: options) {
            print(String(decoding: data, as: UTF8.self))
        } else {
            print(object)
        }
    }

    private static func name(_ window: Any?) -> String {
        guard let w = window as? JSON else { return "" }
        let app = w["app"] as? String ?? "?"
        let title = (w["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return "\(app)\(title.map { ": \($0)" } ?? "") [\(w["id"] ?? "")]"
    }

    private static func printHuman(_ command: String, _ result: Any) {
        let r = result as? JSON ?? [:]
        switch command {
        case "status":
            print("Windy: \(r["state"] ?? "")")
            for case let s as JSON in r["screens"] as? [Any] ?? [] {
                print("\nScreen \(s["screen"] ?? "") · \(s["name"] ?? "") · \(s["layout"] ?? "") · \(s["count"] ?? "") windows")
                for case let t as JSON in s["tiles"] as? [Any] ?? [] {
                    let stacked = (t["stacked"] as? [Any] ?? []).count
                    print("  \(t["tile"] ?? ""). \(name(t["showing"]))\(stacked > 0 ? "  (+\(stacked) stacked)" : "")")
                }
            }
            let floating = r["floating"] as? [Any] ?? []
            if !floating.isEmpty { print("\nFloating: " + floating.map(name).joined(separator: ", ")) }
        case "windows":
            for case let w as JSON in result as? [Any] ?? [] {
                var place = w["tile"].map { "screen \(w["screen"] ?? "?"), tile \($0)" } ?? (w["floating"] as? Bool == true ? "floating" : "not tiled")
                if w["minimized"] as? Bool == true { place = "minimized" }
                print("\(w["focused"] as? Bool == true ? "*" : " ") \(name(w))  ·  \(place)")
            }
        case "workspace.list":
            let list = r["workspaces"] as? [Any] ?? []
            if list.isEmpty { print("No workspaces yet. Save one with `windy workspace save <name>`.") }
            for case let ws as JSON in list {
                let apps = (ws["screens"] as? [Any] ?? []).compactMap { $0 as? JSON }
                    .flatMap { ($0["apps"] as? [Any] ?? []).compactMap { ($0 as? JSON)?["app"] as? String } }
                print("\(ws["name"] ?? ""): \(apps.joined(separator: ", "))")
            }
        case "workspace.open":
            let placed = r["placed"] as? [String] ?? []
            let missing = r["missing"] as? [String] ?? []
            print("Opened \(r["workspace"] ?? ""): \(placed.joined(separator: ", "))")
            if !missing.isEmpty { print("Missing: \(missing.joined(separator: ", "))") }
        case "arrange":
            print("Arranged: " + (r["arranged"] as? [Any] ?? []).map(name).joined(separator: ", "))
            let left = (r["notTileable"] as? [Any] ?? []).map(name) + (r["unknown"] as? [String] ?? [])
            if !left.isEmpty { print("Not placed: " + left.joined(separator: ", ")) }
        default:
            printJSON(result)
        }
    }
}
