import AppKit
import Observation
import WindyCore

/// What the menu bar panel shows, refreshed whenever tiling state changes.
@MainActor @Observable
final class AppModel {
    struct PreviewTile: Identifiable {
        let id: CGWindowID
        let frame: CGRect
        let icon: NSImage?
        let active: Bool
        let zoomed: Bool
        let stacked: Int
    }

    enum Status {
        case tiling, focus, stageManager, setup, off, noAccess

        var color: NSColor {
            switch self {
            case .tiling, .focus: .systemGreen
            case .stageManager, .setup: .systemOrange
            case .off: .systemGray
            case .noAccess: .systemRed
            }
        }
    }

    var status: Status = .setup
    var statusText = ""
    var screenUUID: String?
    var screenFrame: CGRect = .zero
    var layout = ScreenLayout(kind: .grid, count: 4)
    var maxCount = 4
    var preview: [PreviewTile] = []
    var customSizes = false
    var frontAppName: String?
    var frontBundleID: String?
    var noPeek = false
    var cleanSpace = false
    var focusMode = false

    @ObservationIgnored weak var tiler: Tiler?
    @ObservationIgnored var workspaces: Workspaces?
    @ObservationIgnored var showSettings: () -> Void = {}
    @ObservationIgnored var showTour: () -> Void = {}

    func refresh() {
        guard let tiler else { return }
        let prefs = Prefs.shared

        if !Accessibility.isTrusted {
            status = .noAccess; statusText = "Needs Accessibility access"
        } else if !prefs.setupDone {
            status = .setup; statusText = "Waiting for setup to finish"
        } else if !prefs.tilingEnabled {
            status = .off; statusText = "Automatic tiling is off"
        } else if tiler.stageManagerOn {
            status = .stageManager; statusText = "Paused while Stage Manager is on"
        } else if tiler.isFocusMode {
            status = .focus; statusText = "Focus mode · \(windows(tiler.tiledCount))"
        } else {
            status = .tiling; statusText = "Tiling \(windows(tiler.tiledCount))"
        }

        let screen = NSScreen.underPointer ?? NSScreen.main
        screenUUID = screen?.uuid
        screenFrame = screen?.axVisibleFrame ?? .zero
        if let screen {
            layout = prefs.layout(for: screen.uuid)
            maxCount = Layout.capacity(layout.kind, shape: screen.shape)
            customSizes = tiler.hasCustomSizes(screen.uuid)
        }
        preview = []
        if let uuid = screenUUID, let model = tiler.tiles(onDisplay: uuid) {
            preview = model.tiles.compactMap { tile in
                guard let frame = tiler.assigned[tile.top] else { return nil }
                return PreviewTile(id: tile.top, frame: frame, icon: tiler.tracker.windows[tile.top]?.icon,
                                   active: tile.stack.contains(tiler.focused ?? 0),
                                   zoomed: model.zoomed == tile.top, stacked: tile.stack.count)
            }
        }

        let front = NSWorkspace.shared.frontmostApplication
        let mine = front?.processIdentifier == getpid()
        if !mine {
            frontAppName = front?.localizedName
            frontBundleID = front?.bundleIdentifier
        }
        noPeek = tiler.noPeek
        cleanSpace = tiler.cleanSpace != nil
        focusMode = tiler.isFocusMode
    }

    private func windows(_ n: Int) -> String { n == 1 ? "1 window" : "\(n) windows" }
}
