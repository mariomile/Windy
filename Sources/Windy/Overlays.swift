import AppKit

/// A click-through window Windy draws above or below other apps' windows.
final class OverlayWindow: NSWindow {
    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = .normal
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class BorderView: NSView {
    var color: NSColor = .systemBlue { didSet { needsDisplay = true } }
    var width: CGFloat = 3 { didSet { needsDisplay = true } }
    var radius: CGFloat = 12 { didSet { needsDisplay = true } }
    var glow = false { didSet { needsDisplay = true } }
    static let padding: CGFloat = 14

    override func draw(_ dirtyRect: NSRect) {
        let inset = Self.padding - width / 2
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius)
        path.lineWidth = width
        NSGraphicsContext.saveGraphicsState()
        if glow {
            let shadow = NSShadow()
            shadow.shadowColor = color.withAlphaComponent(0.9)
            shadow.shadowBlurRadius = 12
            shadow.set()
            color.withAlphaComponent(0.85).setStroke()
        } else {
            color.setStroke()
        }
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Active-window highlight, No peek dimming and the Clean Space background.
@MainActor
final class Overlays {
    private let tiler: Tiler
    private let prefs = Prefs.shared
    private var borders: [CGWindowID: OverlayWindow] = [:]
    private var dims: [String: OverlayWindow] = [:]
    private var cleanBackground: OverlayWindow?

    init(tiler: Tiler) { self.tiler = tiler }

    func update() {
        updateBorders()
        updateNoPeek()
        updateCleanSpace()
    }

    // MARK: Borders

    private func updateBorders() {
        var wanted: [CGWindowID: Bool] = [:]  // window → is active
        if tiler.isActive, prefs.highlight != .none, NSEvent.pressedMouseButtons == 0 {
            if let id = tiler.focused, tiler.locate(id) != nil { wanted[id] = true }
            if prefs.highlight == .all {
                for tiles in tiler.activeTiles {
                    for tile in tiles.tiles where wanted[tile.top] == nil { wanted[tile.top] = false }
                }
            }
        }

        for (id, window) in borders where wanted[id] == nil {
            window.orderOut(nil)
            borders[id] = nil
        }
        for (id, active) in wanted {
            guard let frame = tiler.tracker.windows[id]?.element.frame else { continue }
            let window = borders[id] ?? makeBorder()
            borders[id] = window
            let view = window.contentView as! BorderView
            view.color = active ? prefs.highlightColor : NSColor.secondaryLabelColor.withAlphaComponent(0.5)
            view.width = active ? CGFloat(prefs.borderWidth) : 1.5
            view.radius = CGFloat(prefs.cornerRadius)
            view.glow = active && prefs.highlight == .glow
            let pad = BorderView.padding
            window.setFrame(flipped(frame).insetBy(dx: -pad, dy: -pad), display: true)
            window.order(.above, relativeTo: Int(id))
        }
    }

    private func makeBorder() -> OverlayWindow {
        let window = OverlayWindow()
        window.contentView = BorderView()
        return window
    }

    // MARK: No peek

    private func updateNoPeek() {
        guard tiler.noPeek, let focused = tiler.focused else {
            for window in dims.values { window.orderOut(nil) }
            dims.removeAll()
            return
        }
        let screens = NSScreen.screens
        let uuids = Set(screens.map(\.uuid))
        for (uuid, window) in dims where !uuids.contains(uuid) { window.orderOut(nil); dims[uuid] = nil }

        for screen in screens {
            let window = dims[screen.uuid] ?? makeDim()
            dims[screen.uuid] = window
            window.setFrame(screen.frame, display: false)
            let content = window.contentView!
            let blur = content.subviews.first as! NSVisualEffectView
            blur.isHidden = !prefs.noPeekBlur
            content.layer?.backgroundColor = NSColor.black.withAlphaComponent(CGFloat(prefs.noPeekDim)).cgColor
            // Directly below the active window: everything else on every screen sits underneath.
            window.order(.below, relativeTo: Int(focused))
        }
    }

    private func makeDim() -> OverlayWindow {
        let window = OverlayWindow()
        let content = NSView()
        content.wantsLayer = true
        let blur = NSVisualEffectView()
        blur.blendingMode = .behindWindow
        blur.material = .fullScreenUI
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        content.addSubview(blur)
        window.contentView = content
        blur.frame = content.bounds
        return window
    }

    // MARK: Clean Space

    private func updateCleanSpace() {
        guard let clean = tiler.cleanSpace, let screen = NSScreen.with(uuid: clean.screen) else {
            cleanBackground?.orderOut(nil)
            cleanBackground = nil
            return
        }
        let window = cleanBackground ?? OverlayWindow()
        cleanBackground = window
        window.isOpaque = true
        window.backgroundColor = prefs.cleanBackground.color
        window.setFrame(screen.frame, display: true)
        window.order(.below, relativeTo: Int(clean.window))
    }
}
