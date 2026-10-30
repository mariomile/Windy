/// A saved setup: which apps go on which screen, in which layout and order.
/// Stored as JSON so people and agents can write one by hand.
public struct Workspace: Codable, Equatable, Sendable {
    public var name: String
    public var screens: [WorkspaceScreen]

    public init(name: String, screens: [WorkspaceScreen]) {
        self.name = name
        self.screens = screens
    }
}

public struct WorkspaceScreen: Codable, Equatable, Sendable {
    /// 1-based display number as listed by `windy status`. Omitted means the main display.
    public var screen: Int?
    public var layout: LayoutKind?
    /// Windows that tile on this screen. Omitted means one per app listed.
    public var count: Int?
    /// In tile order: the first is the primary window.
    public var apps: [WorkspaceApp]

    public init(screen: Int? = nil, layout: LayoutKind? = nil, count: Int? = nil, apps: [WorkspaceApp]) {
        self.screen = screen
        self.layout = layout
        self.count = count
        self.apps = apps
    }
}

public struct WorkspaceApp: Codable, Equatable, Sendable {
    /// App name ("Safari") or bundle identifier ("com.apple.Safari").
    public var app: String
    /// Optional URL or file path to open with the app, such as a project folder or http://localhost:3000.
    public var open: String?

    public init(app: String, open: String? = nil) {
        self.app = app
        self.open = open
    }
}
