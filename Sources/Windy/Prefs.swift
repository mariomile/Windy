import AppKit
import Observation
import ServiceManagement
import WindyCore

enum Highlight: String, CaseIterable, Identifiable {
    case none, active, all, glow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "None"
        case .active: "Active border"
        case .all: "All borders"
        case .glow: "Glow"
        }
    }
}

enum ShortcutPrefix: String, CaseIterable, Identifiable {
    case controlOption, optionCommand, controlShift
    var id: String { rawValue }
    var symbols: String {
        switch self {
        case .controlOption: "⌃⌥"
        case .optionCommand: "⌥⌘"
        case .controlShift: "⌃⇧"
        }
    }
}

enum CleanBackground: String, CaseIterable, Identifiable {
    case graphite, mist, stone
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var color: NSColor {
        switch self {
        case .graphite: NSColor(red: 0.16, green: 0.17, blue: 0.19, alpha: 1)
        case .mist: NSColor(red: 0.86, green: 0.89, blue: 0.92, alpha: 1)
        case .stone: NSColor(red: 0.62, green: 0.60, blue: 0.56, alpha: 1)
        }
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Main window share. Zero means equal shares.
enum MainSize: Double, CaseIterable, Identifiable {
    case equal = 0, half = 0.5, sixty = 0.6, twoThirds = 0.6667
    var id: Double { rawValue }
    var title: String {
        switch self {
        case .equal: "Equal"
        case .half: "Half"
        case .sixty: "60%"
        case .twoThirds: "Two-thirds"
        }
    }
    var ratio: Double? { self == .equal ? nil : rawValue }
}

struct ScreenLayout: Codable, Equatable {
    var kind: LayoutKind
    var count: Int
}

/// Every user setting, saved to UserDefaults as soon as it changes.
@MainActor @Observable
final class Prefs {
    static let shared = Prefs()

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored var onChange: (() -> Void)?

    var setupDone: Bool { didSet { save(setupDone, "setupDone") } }
    var tilingEnabled: Bool { didSet { save(tilingEnabled, "tilingEnabled") } }
    var defaultLayout: LayoutKind { didSet { save(defaultLayout.rawValue, "defaultLayout") } }
    var defaultCount: Int { didSet { save(defaultCount, "defaultCount") } }
    var mainSize: MainSize { didSet { save(mainSize.rawValue, "mainSize") } }
    var gap: Double { didSet { save(gap, "gap") } }
    var stackWhenFull: Bool { didSet { save(stackWhenFull, "stackWhenFull") } }
    var highlight: Highlight { didSet { save(highlight.rawValue, "highlight") } }
    var highlightColor: NSColor { didSet { save(highlightColor.hex, "highlightColor") } }
    var borderWidth: Double { didSet { save(borderWidth, "borderWidth") } }
    var cornerRadius: Double { didSet { save(cornerRadius, "cornerRadius") } }
    var noPeekDim: Double { didSet { save(noPeekDim, "noPeekDim") } }
    var noPeekBlur: Bool { didSet { save(noPeekBlur, "noPeekBlur") } }
    var cleanBackground: CleanBackground { didSet { save(cleanBackground.rawValue, "cleanBackground") } }
    var focusFollowsMouse: Bool { didSet { save(focusFollowsMouse, "focusFollowsMouse") } }
    var appearance: Appearance { didSet { save(appearance.rawValue, "appearance"); NSApp.appearance = appearance.nsAppearance } }
    var prefix: ShortcutPrefix { didSet { save(prefix.rawValue, "prefix") } }
    var excludedApps: [String] { didSet { save(excludedApps, "excludedApps") } }
    var screenLayouts: [String: ScreenLayout] {
        didSet { save(try? JSONEncoder().encode(screenLayouts), "screenLayouts") }
    }

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            "tilingEnabled": true, "defaultLayout": "grid", "defaultCount": 4, "mainSize": 0.0, "gap": 8.0,
            "stackWhenFull": true, "highlight": "active", "highlightColor": "#4F7CFF", "borderWidth": 3.0,
            "cornerRadius": 12.0, "noPeekDim": 0.5, "noPeekBlur": true, "cleanBackground": "graphite",
            "appearance": "system", "prefix": "controlOption",
        ])
        setupDone = d.bool(forKey: "setupDone")
        tilingEnabled = d.bool(forKey: "tilingEnabled")
        defaultLayout = LayoutKind(rawValue: d.string(forKey: "defaultLayout") ?? "") ?? .grid
        defaultCount = d.integer(forKey: "defaultCount")
        mainSize = MainSize(rawValue: d.double(forKey: "mainSize")) ?? .equal
        gap = d.double(forKey: "gap")
        stackWhenFull = d.bool(forKey: "stackWhenFull")
        highlight = Highlight(rawValue: d.string(forKey: "highlight") ?? "") ?? .active
        highlightColor = NSColor(hex: d.string(forKey: "highlightColor") ?? "") ?? .systemBlue
        borderWidth = d.double(forKey: "borderWidth")
        cornerRadius = d.double(forKey: "cornerRadius")
        noPeekDim = d.double(forKey: "noPeekDim")
        noPeekBlur = d.bool(forKey: "noPeekBlur")
        cleanBackground = CleanBackground(rawValue: d.string(forKey: "cleanBackground") ?? "") ?? .graphite
        focusFollowsMouse = d.bool(forKey: "focusFollowsMouse")
        appearance = Appearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        prefix = ShortcutPrefix(rawValue: d.string(forKey: "prefix") ?? "") ?? .controlOption
        excludedApps = d.stringArray(forKey: "excludedApps") ?? []
        screenLayouts = d.data(forKey: "screenLayouts")
            .flatMap { try? JSONDecoder().decode([String: ScreenLayout].self, from: $0) } ?? [:]
    }

    private func save(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
        onChange?()
    }

    func layout(for screen: String) -> ScreenLayout {
        screenLayouts[screen] ?? ScreenLayout(kind: defaultLayout, count: defaultCount)
    }

    func isExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return excludedApps.contains(bundleID)
    }

    func setExcluded(_ bundleID: String, _ excluded: Bool) {
        excludedApps.removeAll { $0 == bundleID }
        if excluded { excludedApps.append(bundleID) }
    }

    var openAtLogin: Bool {
        get { access(keyPath: \.openAtLogin); return SMAppService.mainApp.status == .enabled }
        set {
            withMutation(keyPath: \.openAtLogin) {
                if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
            }
        }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hex: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
