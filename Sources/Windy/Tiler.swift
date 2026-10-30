import AppKit
import WindyCore

/// One place in a layout. It can hold a stack of windows that share its frame; `top` is the one showing.
struct Tile {
    var stack: [CGWindowID]
    var top: CGWindowID

    init(_ id: CGWindowID) {
        stack = [id]
        top = id
    }
}

/// The tiles of one display, in the order their windows arrived.
final class ScreenModel {
    let uuid: String
    var tiles: [Tile] = []
    /// Sizes the user set by dragging or with ⌃⌥=/-, per layout and tile count.
    var weights: [String: SplitWeights] = [:]
    /// The window zoomed by focus mode, if any.
    var focusWindow: CGWindowID?

    init(uuid: String) { self.uuid = uuid }

    func index(of id: CGWindowID) -> Int? { tiles.firstIndex { $0.stack.contains(id) } }
    var windowCount: Int { tiles.reduce(0) { $0 + $1.stack.count } }
}

@MainActor
final class Tiler {
    let tracker: WindowTracker
    let prefs = Prefs.shared

    private(set) var models: [String: ScreenModel] = [:]
    private(set) var floating: Set<CGWindowID> = []
    /// Floating only because their screen was full; they get a tile when one frees up.
    private var overflow: [CGWindowID] = []
    private(set) var focused: CGWindowID?
    /// Most recently focused windows first.
    private(set) var mru: [CGWindowID] = []
    /// The frame Windy last gave each window.
    private(set) var assigned: [CGWindowID: CGRect] = [:]
    private(set) var cleanSpace: (screen: String, window: CGWindowID)?
    var noPeek = false { didSet { changed() } }
    var stageManagerOn = false { didSet { if stageManagerOn != oldValue { reconcile() } } }

    var onStateChange: (() -> Void)?

    private var ownChangeUntil: [CGWindowID: Date] = [:]
    private var lastSnapBack: [CGWindowID: Date] = [:]
    private var dragged: Set<CGWindowID> = []
    private var reconcileScheduled = false

    init(tracker: WindowTracker) {
        self.tracker = tracker
    }

    var isActive: Bool {
        prefs.tilingEnabled && prefs.setupDone && Accessibility.isTrusted && !stageManagerOn
    }

    var tiledCount: Int { models.values.reduce(0) { $0 + $1.windowCount } }
    var gap: CGFloat { CGFloat(prefs.gap) }

    // MARK: Keeping tiles in sync with the windows on screen

    func scheduleReconcile() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.reconcileScheduled = false
            self?.reconcile()
        }
    }

    /// Drops closed windows, adds new ones and re-applies every screen that changed.
    func reconcile() {
        guard isActive else {
            models.removeAll()
            assigned.removeAll()
            cleanSpace = nil
            changed()
            return
        }

        let screens = NSScreen.screens
        let uuids = Set(screens.map(\.uuid))
        for uuid in models.keys where !uuids.contains(uuid) { models[uuid] = nil }
        for screen in screens where models[screen.uuid] == nil { models[screen.uuid] = ScreenModel(uuid: screen.uuid) }

        let visible = tracker.visibleWindows().filter { !prefs.isExcluded($0.bundleID) }
        let ids = Set(visible.map(\.id))
        floating.formIntersection(Set(tracker.windows.keys))
        overflow.removeAll { !floating.contains($0) }
        var dirty = Set<String>()

        // Native tabs swap which window ID is on screen. A newcomer from the same app sitting
        // where a vanished window was takes over its slot instead of moving to the end.
        var tiledNow = Set(models.values.flatMap { $0.tiles.flatMap(\.stack) })
        var newcomers = visible.filter { !tiledNow.contains($0.id) && !floating.contains($0.id) }
        for model in models.values {
            for gone in model.tiles.flatMap(\.stack) where !ids.contains(gone) {
                guard let slot = assigned[gone], let pid = tracker.windows[gone]?.pid,
                      let k = newcomers.firstIndex(where: { w in
                          w.pid == pid && (w.element.frame.map { abs($0.minX - slot.minX) < 30 && abs($0.minY - slot.minY) < 30 } ?? false)
                      }),
                      let i = model.index(of: gone) else { continue }
                let id = newcomers.remove(at: k).id
                model.tiles[i].stack = model.tiles[i].stack.map { $0 == gone ? id : $0 }
                if model.tiles[i].top == gone { model.tiles[i].top = id }
                if model.focusWindow == gone { model.focusWindow = id }
                if cleanSpace?.window == gone { cleanSpace = (model.uuid, id) }
                assigned[id] = slot
                assigned[gone] = nil
                tiledNow.insert(id)
                dirty.insert(model.uuid)
            }
        }

        for model in models.values {
            for id in model.tiles.flatMap(\.stack) where !ids.contains(id) {
                remove(id, from: model, raiseNext: false)
                dirty.insert(model.uuid)
            }
            // Layout or count may have changed in Settings: stack or unstack to fit.
            if fit(model) { dirty.insert(model.uuid) }
        }
        if let clean = cleanSpace, !ids.contains(clean.window) {
            cleanSpace = nil
            dirty.insert(clean.screen)
        }

        let tiled = Set(models.values.flatMap { $0.tiles.flatMap(\.stack) })
        for window in visible where !tiled.contains(window.id) && !floating.contains(window.id) {
            guard let screen = screen(for: window), let model = models[screen.uuid] else { continue }
            add(window.id, to: model)
            dirty.insert(model.uuid)
        }

        for uuid in dirty { apply(uuid) }
        changed()
    }

    private func screen(for window: TrackedWindow) -> NSScreen? {
        guard let frame = window.element.frame else { return NSScreen.underPointer }
        return NSScreen.containing(axPoint: CGPoint(x: frame.midX, y: frame.midY))
    }

    func capacity(_ model: ScreenModel) -> Int {
        let layout = prefs.layout(for: model.uuid)
        let shape = NSScreen.with(uuid: model.uuid)?.shape ?? .normal
        return min(max(1, layout.count), Layout.capacity(layout.kind, shape: shape))
    }

    private func add(_ id: CGWindowID, to model: ScreenModel) {
        if model.tiles.count < capacity(model) {
            model.tiles.append(Tile(id))
        } else if prefs.stackWhenFull {
            // A full screen stacks the new window on top of the tile you're working in.
            let i = activeTile(in: model) ?? model.tiles.count - 1
            model.tiles[i].stack.append(id)
            model.tiles[i].top = id
        } else {
            floating.insert(id)
            overflow.append(id)
            center(id, on: model.uuid)
        }
    }

    private func activeTile(in model: ScreenModel) -> Int? {
        for id in mru { if let i = model.index(of: id) { return i } }
        return nil
    }

    private func remove(_ id: CGWindowID, from model: ScreenModel, raiseNext: Bool = true) {
        assigned[id] = nil
        if model.focusWindow == id { model.focusWindow = nil }
        if cleanSpace?.window == id { cleanSpace = nil }
        guard let i = model.index(of: id) else { return }
        model.tiles[i].stack.removeAll { $0 == id }
        if model.tiles[i].stack.isEmpty {
            model.tiles.remove(at: i)
            unstackIfRoom(model)
        } else if model.tiles[i].top == id {
            let next = model.tiles[i].stack.last!
            model.tiles[i].top = next
            if raiseNext { tracker.windows[next]?.element.perform(kAXRaiseAction) }
        }
    }

    /// When a tile frees up, a window waiting in a stack, or floating because the screen was full,
    /// gets its own place.
    private func unstackIfRoom(_ model: ScreenModel) {
        while model.tiles.count < capacity(model), let j = model.tiles.lastIndex(where: { $0.stack.count > 1 }) {
            let waiting = model.tiles[j].stack.first { $0 != model.tiles[j].top }!
            model.tiles[j].stack.removeAll { $0 == waiting }
            model.tiles.append(Tile(waiting))
        }
        while model.tiles.count < capacity(model), let k = overflow.firstIndex(where: { id in
            tracker.windows[id].flatMap { screen(for: $0) }?.uuid == model.uuid
        }) {
            let id = overflow.remove(at: k)
            floating.remove(id)
            model.tiles.append(Tile(id))
        }
    }

    /// Stacks extra tiles or unstacks waiting windows so a screen matches its window count.
    /// Returns whether anything moved.
    @discardableResult
    private func fit(_ model: ScreenModel) -> Bool {
        let before = model.tiles.map(\.stack)
        let cap = capacity(model)
        while model.tiles.count > cap {
            let extra = model.tiles.removeLast()
            model.tiles[model.tiles.count - 1].stack.insert(contentsOf: extra.stack, at: 0)
        }
        unstackIfRoom(model)
        return model.tiles.map(\.stack) != before
    }

    func locate(_ id: CGWindowID) -> (model: ScreenModel, tile: Int)? {
        for model in models.values { if let i = model.index(of: id) { return (model, i) } }
        return nil
    }

    // MARK: Placing windows

    private func tree(for model: ScreenModel, on screen: NSScreen) -> (LayoutNode, String) {
        let layout = prefs.layout(for: model.uuid)
        let n = max(1, model.tiles.count)
        let tree = Layout.tree(kind: layout.kind, count: n, mainRatio: prefs.mainSize.ratio, shape: screen.shape)
        return (tree, "\(layout.kind.rawValue)-\(n)")
    }

    /// Moves every window on a screen to its tile.
    func apply(_ uuid: String) {
        guard isActive, let model = models[uuid], let screen = NSScreen.with(uuid: uuid) else {
            changed()
            return
        }
        // A zoomed window that left this screen (swap, move, float) ends its zoom.
        if let zoomed = model.focusWindow, model.index(of: zoomed) == nil { model.focusWindow = nil }
        if let clean = cleanSpace, clean.screen == uuid, model.index(of: clean.window) == nil { cleanSpace = nil }
        guard !model.tiles.isEmpty else {
            changed()
            return
        }
        let area = screen.axVisibleFrame
        let full = area.insetBy(dx: gap, dy: gap)
        let (tree, key) = tree(for: model, on: screen)
        let leaves = Layout.rects(tree, in: area, gap: gap, weights: model.weights[key] ?? [:]).leaves
        let zoomed = cleanSpace?.screen == uuid ? cleanSpace?.window : model.focusWindow

        var placed: [CGWindowID] = []
        for (i, tile) in model.tiles.enumerated() {
            guard let frame = leaves[i] else { continue }
            for id in tile.stack {
                place(id, id == zoomed ? full : frame)
                placed.append(id)
            }
        }
        if let zoomed { tracker.windows[zoomed]?.element.perform(kAXRaiseAction) }
        checkFit(placed)
        changed()
    }

    private func place(_ id: CGWindowID, _ frame: CGRect) {
        guard let window = tracker.windows[id] else { return }
        assigned[id] = frame
        if let current = window.element.frame,
           abs(current.minX - frame.minX) < 1, abs(current.minY - frame.minY) < 1,
           abs(current.width - frame.width) < 1, abs(current.height - frame.height) < 1 { return }
        ownChangeUntil[id] = Date().addingTimeInterval(0.6)

        // Enhanced UI (turned on by assistive apps) makes some apps animate every AX resize.
        let app = AXUIElementCreateApplication(window.pid)
        let enhanced = app.bool("AXEnhancedUserInterface")
        if enhanced { app.set("AXEnhancedUserInterface", false as CFBoolean) }
        window.element.setFrame(frame)
        if enhanced { app.set("AXEnhancedUserInterface", true as CFBoolean) }
    }

    /// Windows that refuse to get as small as their tile float in the middle of the screen instead.
    private func checkFit(_ ids: [CGWindowID]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            var refloated = Set<String>()
            for id in ids {
                guard let target = assigned[id], let window = tracker.windows[id], let actual = window.element.frame,
                      let (model, _) = locate(id), model.focusWindow != id, cleanSpace?.window != id else { continue }
                if actual.width > target.width + 30 || actual.height > target.height + 30 {
                    remove(id, from: model)
                    floating.insert(id)
                    center(id, on: model.uuid)
                    refloated.insert(model.uuid)
                }
            }
            for uuid in refloated { apply(uuid) }
        }
    }

    private func center(_ id: CGWindowID, on uuid: String) {
        guard let window = tracker.windows[id], let screen = NSScreen.with(uuid: uuid),
              let frame = window.element.frame else { return }
        let area = screen.axVisibleFrame
        let size = CGSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
        ownChangeUntil[id] = Date().addingTimeInterval(0.6)
        window.element.setFrame(CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                                       width: size.width, height: size.height))
        assigned[id] = nil
    }

    func applyAll() {
        for uuid in models.keys { apply(uuid) }
    }

    private func changed() {
        onStateChange?()
    }

    // MARK: Focus

    func focusChanged() {
        scheduleReconcile()
        let id = tracker.focusedWindowID()
        focused = id
        guard let id else { changed(); return }
        mru.removeAll { $0 == id }
        mru.insert(id, at: 0)
        if mru.count > 64 { mru.removeLast() }

        if let (model, i) = locate(id) {
            model.tiles[i].top = id
            // Clicking another window on a zoomed screen goes back to the layout.
            if let zoomed = model.focusWindow, zoomed != id {
                model.focusWindow = nil
                apply(model.uuid)
            }
            // Clean Space shows whichever window you bring forward on that screen.
            if let clean = cleanSpace, clean.screen == model.uuid, clean.window != id {
                cleanSpace = (clean.screen, id)
                apply(model.uuid)
            }
        }
        changed()
    }

    func focus(_ id: CGWindowID) {
        tracker.windows[id]?.focus()
    }

    // MARK: User moving and resizing windows

    func geometryChanged(_ id: CGWindowID) {
        if let until = ownChangeUntil[id], until > Date(),
           let frame = tracker.windows[id]?.element.frame, let target = assigned[id] ?? Optional(frame),
           abs(frame.minX - target.minX) < 2, abs(frame.minY - target.minY) < 2,
           abs(frame.width - target.width) < 2, abs(frame.height - target.height) < 2 { return }
        if NSEvent.pressedMouseButtons & 1 != 0 {
            dragged.insert(id)
            changed()
            return
        }
        // Moved by the app itself or another tool: put it back, at most once a second.
        guard locate(id) != nil else { changed(); return }
        if let last = lastSnapBack[id], Date().timeIntervalSince(last) < 1 { return }
        lastSnapBack[id] = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            reconcile()
            if let (model, _) = locate(id) { apply(model.uuid) }
        }
    }

    /// Called on every left mouse-up. Finishes drags: resize, swap, stack, move to another screen, or snap back.
    func mouseUp(modifiers: NSEvent.ModifierFlags) {
        let ids = dragged
        dragged.removeAll()
        for id in ids { finishDrag(id, modifiers: modifiers) }
    }

    private func finishDrag(_ id: CGWindowID, modifiers: NSEvent.ModifierFlags) {
        guard let window = tracker.windows[id], let frame = window.element.frame,
              let (model, i) = locate(id), let old = assigned[id] else { return }

        let resized = abs(frame.width - old.width) > 2 || abs(frame.height - old.height) > 2
        if resized {
            if model.focusWindow == nil, cleanSpace?.window != id, let screen = NSScreen.with(uuid: model.uuid) {
                let (tree, key) = tree(for: model, on: screen)
                model.weights[key] = Layout.fit(i, to: frame, tree: tree, in: screen.axVisibleFrame, gap: gap,
                                                weights: model.weights[key] ?? [:])
            }
            apply(model.uuid)
            return
        }

        let point = flippedPoint(NSEvent.mouseLocation)
        guard let screen = NSScreen.containing(axPoint: point), let target = models[screen.uuid] else {
            apply(model.uuid)
            return
        }
        let targetTile = target.tiles.indices.first { j in
            !(target === model && j == i) && (assigned[target.tiles[j].top]?.contains(point) ?? false)
        }

        if modifiers.contains(.command), let j = targetTile {
            if modifiers.contains(.option) {
                addToStack(id, from: model, onto: target.tiles[j].top)
            } else {
                swapTiles(model, i, target, j)
            }
        } else if target !== model {
            moveToNewTile(id, from: model, to: target)
        }
        apply(model.uuid)
        if target !== model { apply(target.uuid) }
    }

    private func swapTiles(_ a: ScreenModel, _ i: Int, _ b: ScreenModel, _ j: Int) {
        if a === b {
            a.tiles.swapAt(i, j)
        } else {
            let t = a.tiles[i]
            a.tiles[i] = b.tiles[j]
            b.tiles[j] = t
        }
    }

    @discardableResult
    private func moveToNewTile(_ id: CGWindowID, from model: ScreenModel, to target: ScreenModel) -> Bool {
        guard target.tiles.count < capacity(target) else { return false }
        remove(id, from: model)
        target.tiles.append(Tile(id))
        return true
    }

    private func addToStack(_ id: CGWindowID, from model: ScreenModel, onto top: CGWindowID) {
        remove(id, from: model)
        guard let (target, j) = locate(top) else { return }
        target.tiles[j].stack.append(id)
        target.tiles[j].top = id
    }

    // MARK: Commands

    private var focusedLocation: (model: ScreenModel, tile: Int)? {
        focused.flatMap { locate($0) }
    }

    /// The screen commands act on: the active window's, or the one under the pointer.
    var currentScreenUUID: String? {
        focusedLocation?.model.uuid ?? NSScreen.underPointer?.uuid
    }

    func toggleFocusMode() {
        guard let id = focused, let (model, _) = locate(id) else { return }
        model.focusWindow = model.focusWindow == id ? nil : id
        apply(model.uuid)
    }

    var isFocusMode: Bool { focusedLocation?.model.focusWindow != nil }

    func toggleCleanSpace() {
        if let clean = cleanSpace {
            cleanSpace = nil
            apply(clean.screen)
            return
        }
        guard let id = focused, let (model, _) = locate(id) else { return }
        cleanSpace = (model.uuid, id)
        apply(model.uuid)
    }

    func endCleanSpace() {
        guard let clean = cleanSpace else { return }
        cleanSpace = nil
        apply(clean.screen)
    }

    func cycleStack(_ step: Int) {
        guard let (model, i) = focusedLocation, model.tiles[i].stack.count > 1 else { return }
        let stack = model.tiles[i].stack
        let k = stack.firstIndex(of: model.tiles[i].top) ?? 0
        let next = stack[(k + step + stack.count) % stack.count]
        model.tiles[i].top = next
        focus(next)
    }

    private func tileRects(_ model: ScreenModel) -> [Int: CGRect] {
        var out: [Int: CGRect] = [:]
        for (i, tile) in model.tiles.enumerated() { out[i] = assigned[tile.top] }
        return out
    }

    /// Swaps with the neighbor that way, or moves to the next screen past the edge.
    func swap(_ direction: Direction) {
        guard let id = focused, let (model, i) = locate(id), let screen = NSScreen.with(uuid: model.uuid) else { return }
        let rects = tileRects(model)
        if let origin = rects[i], let j = Layout.neighbor(of: origin, in: rects, direction: direction) {
            model.tiles.swapAt(i, j)
            apply(model.uuid)
            return
        }
        guard let next = screen.neighbor(direction), let target = models[next.uuid] else { return }
        if !moveToNewTile(id, from: model, to: target) {
            // Full screen: trade places with the tile nearest to where the window comes in.
            let origin = assigned[id] ?? .zero
            let targetRects = tileRects(target)
            guard let j = targetRects.min(by: {
                hypot($0.value.midX - origin.midX, $0.value.midY - origin.midY)
                    < hypot($1.value.midX - origin.midX, $1.value.midY - origin.midY)
            })?.key else { return }
            swapTiles(model, i, target, j)
        }
        apply(model.uuid)
        apply(target.uuid)
        focus(id)
    }

    func makePrimary() {
        guard let (model, i) = focusedLocation, i != 0 else { return }
        model.tiles.swapAt(0, i)
        apply(model.uuid)
    }

    func resize(by delta: Double) {
        guard let (model, i) = focusedLocation, model.focusWindow == nil,
              let screen = NSScreen.with(uuid: model.uuid) else { return }
        let (tree, key) = tree(for: model, on: screen)
        let before = model.weights[key] ?? [:]
        let after = Layout.grow(i, by: delta, tree: tree, weights: before)
        if after == before { NSSound.beep() }
        model.weights[key] = after
        apply(model.uuid)
    }

    func resetSizes(_ uuid: String? = nil) {
        guard let uuid = uuid ?? currentScreenUUID, let model = models[uuid] else { return }
        model.weights.removeAll()
        apply(uuid)
    }

    func hasCustomSizes(_ uuid: String) -> Bool { !(models[uuid]?.weights.isEmpty ?? true) }

    func focusNeighbor(_ step: Int) {
        guard let (model, i) = focusedLocation, model.tiles.count > 1 else { return }
        focus(model.tiles[(i + step + model.tiles.count) % model.tiles.count].top)
    }

    func toggleFloat() {
        guard let id = focused else { return }
        overflow.removeAll { $0 == id }
        if floating.contains(id) {
            floating.remove(id)
            reconcile()
        } else if let (model, _) = locate(id) {
            remove(id, from: model)
            floating.insert(id)
            center(id, on: model.uuid)
            apply(model.uuid)
        }
    }

    /// Changes a screen's layout or window count, stacking or unstacking windows to fit.
    func setLayout(kind: LayoutKind? = nil, count: Int? = nil, screen uuid: String? = nil) {
        guard let uuid = uuid ?? currentScreenUUID else { return }
        var layout = prefs.layout(for: uuid)
        if let kind { layout.kind = kind }
        if let count { layout.count = count }
        prefs.screenLayouts[uuid] = layout
        guard let model = models[uuid] else { return }
        fit(model)
        apply(uuid)
    }

    // MARK: Focus follows mouse

    private var hoverWork: DispatchWorkItem?

    func hover(at point: CGPoint) {
        hoverWork?.cancel()
        guard prefs.focusFollowsMouse, isActive, NSEvent.pressedMouseButtons == 0 else { return }
        guard let screen = NSScreen.containing(axPoint: point), let model = models[screen.uuid],
              model.focusWindow == nil, cleanSpace?.screen != screen.uuid else { return }
        // Only the window actually under the pointer, and only if it's a tile's top window.
        guard let target = Self.topWindow(at: point), model.tiles.contains(where: { $0.top == target }),
              target != focused else { return }
        let work = DispatchWorkItem { [weak self] in self?.focus(target) }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// The frontmost normal window containing an AX point (CG window bounds share AX coordinates).
    static func topWindow(at point: CGPoint) -> CGWindowID? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for w in info where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict), bounds.contains(point) else { continue }
            if (w[kCGWindowOwnerPID as String] as? pid_t) == getpid() { continue }
            return (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        return nil
    }
}
