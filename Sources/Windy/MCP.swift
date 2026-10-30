import Foundation

/// `windy mcp`: a Model Context Protocol server over stdio, so agents like Claude can arrange
/// windows. Each tool forwards to the running app, exactly like the `windy` command does.
enum MCP {
    private static let window: JSON = ["type": "string", "description": "Window ID, app name, bundle ID, part of the title, or \"App: title text\". Defaults to the active window."]
    private static let screen: JSON = ["type": "integer", "description": "1-based screen number from windy_status. Defaults to the active window's screen."]
    private static let layout: JSON = ["type": "string", "enum": ["grid", "columns", "rows", "side"],
                                 "description": "grid: primary left, others fold to the right, 4 make a 2×2. columns: side by side. rows: stacked top to bottom. side: primary left, others in one right column."]
    private static let count: JSON = ["type": "integer", "minimum": 1, "maximum": 5, "description": "How many windows tile on the screen; extra windows stack."]

    private static func tool(_ name: String, _ command: String, _ description: String,
                             _ properties: JSON = [:], required: [String] = []) -> (JSON, String) {
        (["name": name, "description": description,
          "inputSchema": ["type": "object", "properties": properties, "required": required]], command)
    }

    private static let tools: [(definition: JSON, command: String)] = [
        tool("windy_status", "status", "Screens, their layouts, and which window is in each tile. Start here."),
        tool("windy_list_windows", "windows", "Every window with its ID, app, title, screen and tile, most recently used first."),
        tool("windy_set_layout", "layout", "Change a screen's layout and/or how many windows tile on it.",
             ["layout": layout, "count": count, "screen": screen]),
        tool("windy_arrange", "arrange",
             "Put windows in tiles on one screen, in order: the first becomes the primary (biggest) tile. Windows from other screens move over. Example: editor first, browser second, terminal third.",
             ["windows": ["type": "array", "items": ["type": "string"], "description": "Windows in tile order."],
              "layout": layout, "count": count, "screen": screen], required: ["windows"]),
        tool("windy_focus_window", "focus", "Bring a window to the front and give it keyboard focus.",
             ["window": window], required: ["window"]),
        tool("windy_swap", "swap", "Swap a window with its neighbor in a direction, or move it to the next screen past the edge.",
             ["direction": ["type": "string", "enum": ["left", "right", "up", "down"]], "window": window], required: ["direction"]),
        tool("windy_make_primary", "primary", "Move a window into the primary tile.", ["window": window]),
        tool("windy_toggle", "toggle",
             "Turn a mode on or off (omit `on` to toggle). zoom: one window fills its screen. clean_space: one window on a plain background, for screen sharing. no_peek: dim every other window. tiling: Windy's automatic tiling.",
             ["mode": ["type": "string", "enum": ["zoom", "clean_space", "no_peek", "tiling"]], "on": ["type": "boolean"], "window": window],
             required: ["mode"]),
        tool("windy_float", "float", "Take a window out of the layout so it floats, or put a floating window back.", ["window": window]),
        tool("windy_workspace_list", "workspace.list", "Saved workspaces: sets of apps with their screen and layout."),
        tool("windy_workspace_open", "workspace.open", "Open a workspace: launch its apps, open their files or URLs, and lay them out.",
             ["name": ["type": "string"]], required: ["name"]),
        tool("windy_workspace_save", "workspace.save", "Save the windows tiled now as a workspace.",
             ["name": ["type": "string"], "screen": screen], required: ["name"]),
        tool("windy_workspace_define", "workspace.define",
             "Create or replace a workspace. Apps go in tile order; `open` is an optional URL or file path to open with the app, such as a project folder or http://localhost:3000.",
             ["name": ["type": "string"],
              "screens": ["type": "array", "items": [
                  "type": "object",
                  "properties": ["screen": screen, "layout": layout, "count": count,
                                 "apps": ["type": "array", "items": [
                                     "type": "object",
                                     "properties": ["app": ["type": "string", "description": "App name or bundle ID."],
                                                    "open": ["type": "string"]],
                                     "required": ["app"]]]],
                  "required": ["apps"]]]],
             required: ["name", "screens"]),
        tool("windy_workspace_delete", "workspace.delete", "Delete a saved workspace.", ["name": ["type": "string"]], required: ["name"]),
    ]

    private static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    static func run() -> Int32 {
        while let line = readLine() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let data = line.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) else {
                write(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            if let batch = parsed as? [Any] {
                let replies = batch.compactMap { ($0 as? JSON).flatMap(handle) }
                if !replies.isEmpty { write(replies) }
            } else if let message = parsed as? JSON, let reply = handle(message) {
                write(reply)
            } else if !(parsed is JSON) {
                write(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid request"]])
            }
        }
        return 0
    }

    /// One JSON-RPC message in, its response out. Notifications (no id) get none.
    private static func handle(_ message: JSON) -> JSON? {
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? JSON ?? [:]
        guard let id = message["id"], !(id is NSNull) else { return nil }

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            return result(id, [
                "protocolVersion": protocolVersions.contains(asked) ? asked : protocolVersions[0],
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "windy", "version": version],
                "instructions": "Windy tiles macOS windows. Call windy_status first to see screens and tiles, then windy_arrange to place windows in order (first = primary). Workspaces save and reopen whole setups.",
            ])
        case "ping":
            return result(id, [:])
        case "tools/list":
            return result(id, ["tools": tools.map(\.definition)])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            guard let command = tools.first(where: { $0.definition["name"] as? String == name })?.command else {
                return failure(id, -32602, "Unknown tool \(name)")
            }
            let reply = CLI.send(["command": command, "args": params["arguments"] as? JSON ?? [:]])
                ?? ["ok": false, "error": "Couldn't reach the Windy app. Is it installed and running?"]
            let ok = reply["ok"] as? Bool == true
            let payload: Any = ok ? (reply["result"] ?? [:]) : (reply["error"] ?? "Windy couldn't do that.")
            let text: String
            if let string = payload as? String {
                text = string
            } else if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]) {
                text = String(decoding: data, as: UTF8.self)
            } else {
                text = "\(payload)"
            }
            return result(id, ["content": [["type": "text", "text": text]], "isError": !ok])
        default:
            return failure(id, -32601, "Method not found: \(method)")
        }
    }

    static var version: String {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundle = binary.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: bundle)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private static func result(_ id: Any, _ result: JSON) -> JSON {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func failure(_ id: Any, _ code: Int, _ message: String) -> JSON {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func write(_ object: Any) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        data.append(10)
        FileHandle.standardOutput.write(data)
    }
}
