import AppKit
import WindyCore

/// Turns the windows on screen into tiles and tiles into window frames.
/// Tile state lives in `ScreenTiles` (WindyCore), one per display and Space.
@MainActor
final class Tiler {
    let tracker: WindowTracker
    let prefs = Prefs.shared

    /// Tiles for every display and Space seen. Spaces not showing keep theirs for when you come back.
    private(set) var models: [ScreenKey: ScreenTiles] = [:]
    /// The Space showing on each display, by display UUID.
    private(set) var active: [String: ScreenKey] = [:]
    private(set) var floating: Set<WindowID> = []
    /// Floating only because their screen was full; they get a tile when one frees up.
    private var overflow: [WindowID] = []
    private(set) var focused: WindowID?
    /// Most recently focused windows first.
    private(set) var mru: [WindowID] = []
    /// The frame Windy last gave each window.
    private(set) var assigned: [WindowID: CGRect] = [:]
    private(set) var cleanSpace: (screen: String, window: WindowID)?
    var noPeek = false { didSet { changed() } }
    var stageManagerOn = false { didSet { if stageManagerOn != oldValue { reconcile() } } }

    var onStateChange: (() -> Void)?

    private var ownChangeUntil: [WindowID: Date] = [:]
    private var lastSnapBack: [WindowID: Date] = [:]
    private var dragged: Set<WindowID> = []
    private var reconcileScheduled = false

    init(tracker: WindowTracker) {
        self.tracker = tracker
    }

    var isActive: Bool {
        prefs.tilingEnabled && prefs.setupDone && Accessibility.isTrusted && !stageManagerOn
    }

    var gap: CGFloat { CGFloat(prefs.gap) }

    // MARK: Reading state

    func tiles(onDisplay uuid: String) -> ScreenTiles? { active[uuid].flatMap { models[$0] } }

    var activeTiles: [ScreenTiles] { active.values.compactMap { models[$0] } }

    var tiledCount: Int { activeTiles.reduce(0) { $0 + $1.windowCount } }

    /// The display and tile holding a window, on the Spaces showing now.
    func locate(_ id: WindowID) -> (display: String, tile: Int)? {
        for (display, key) in active {
            if let i = models[key]?.index(of: id) { return (display, i) }
        }
        return nil
    }

    var isFocusMode: Bool {
        guard let display = focusedLocation?.display else { return false }
        return tiles(onDisplay: display)?.zoomed != nil
    }

    func hasCustomSizes(_ uuid: String) -> Bool { !(tiles(onDisplay: uuid)?.weights.isEmpty ?? true) }

    private func edit<T>(_ display: String, _ body: (inout ScreenTiles) -> T) -> T? {
        guard let key = active[display] else { return nil }
        return body(&models[key, default: ScreenTiles()])
    }

    func capacity(_ display: String) -> Int {
        let layout = prefs.layout(for: display)
        let shape = NSScreen.with(uuid: display)?.shape ?? .normal
        return min(max(1, layout.count), Layout.capacity(layout.kind, shape: shape))
    }

    // MARK: Keeping tiles in sync with the windows on screen

    func scheduleReconcile() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.reconcileScheduled = false
            self?.reconcile()
        }
    }

    /// Follows the Space showing on each display. Tiles of a display that goes away (sleep,
    /// clamshell, a resolution change) are kept for when it comes back.
    private func refreshActive() {
        let screens = NSScreen.screens
        active = Dictionary(uniqueKeysWithValues: screens.map { ($0.uuid, $0.key) })
        for key in active.values where models[key] == nil { models[key] = ScreenTiles() }

        // A window belongs to one showing screen only: the one it's on.
        var owners: [WindowID: [String]] = [:]
        for (display, key) in active { for id in models[key]!.windows { owners[id, default: []].append(display) } }
        for (id, displays) in owners where displays.count > 1 {
            let here = tracker.windows[id].flatMap { screen(for: $0) }?.uuid
            let keep = displays.contains(here ?? "") ? here! : displays.sorted()[0]
            for display in displays where display != keep { models[active[display]!]!.remove(id) }
        }
    }

    // MARK: Spaces

    /// Right after a Space switch both Spaces' windows can still be listed as on screen.
    /// Reconciling waits for the switch to settle so neither Space's tiles get mixed up.
    private var settleUntil = Date.distantPast

    func spaceChanged() {
        settleUntil = Date().addingTimeInterval(0.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.tracker.scanAll() }
    }

    /// Drops closed windows, adds new ones and re-applies every screen that changed.
    func reconcile() {
        let wait = settleUntil.timeIntervalSinceNow
        if wait > 0 {
            if !reconcileScheduled {
                reconcileScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    self?.reconcileScheduled = false
                    self?.reconcile()
                }
            }
            return
        }
        guard isActive else {
            models.removeAll()
            active.removeAll()
            assigned.removeAll()
            cleanSpace = nil
            changed()
            return
        }
        refreshActive()

        let visible = tracker.visibleWindows().filter { !prefs.isExcluded($0.bundleID) }
        let ids = Set(visible.map(\.id))
        floating.formIntersection(Set(tracker.windows.keys))
        overflow.removeAll { !floating.contains($0) }
        var dirty = Set<String>()

        // Native tabs swap which window ID is on screen. A newcomer from the same app sitting
        // where a vanished window was takes over its slot instead of moving to the end.
        let tiledNow = Set(activeTiles.flatMap(\.windows))
        var newcomers = visible.filter { !tiledNow.contains($0.id) && !floating.contains($0.id) }
        for (display, key) in active {
            for gone in models[key]!.windows where !ids.contains(gone) {
                guard let slot = assigned[gone], let pid = tracker.windows[gone]?.pid,
                      let k = newcomers.firstIndex(where: { w in
                          w.pid == pid && (w.element.frame.map { abs($0.minX - slot.minX) < 30 && abs($0.minY - slot.minY) < 30 } ?? false)
                      }) else { continue }
                let id = newcomers.remove(at: k).id
                models[key]!.replace(gone, with: id)
                if cleanSpace?.window == gone { cleanSpace = (display, id) }
                assigned[id] = slot
                assigned[gone] = nil
                dirty.insert(display)
            }
        }

        for (display, key) in active {
            for id in models[key]!.windows where !ids.contains(id) {
                assigned[id] = nil
                models[key]!.remove(id)
                if cleanSpace?.window == id { cleanSpace = nil }
                dirty.insert(display)
            }
            // Layout or count may have changed in Settings: stack or unstack to fit.
            if fit(display) { dirty.insert(display) }
        }
        if let clean = cleanSpace, !ids.contains(clean.window) {
            cleanSpace = nil
            dirty.insert(clean.screen)
        }

        let tiled = Set(activeTiles.flatMap(\.windows))
        let showing = Set(active.values)
        for window in visible where !tiled.contains(window.id) && !floating.contains(window.id) {
            guard let screen = screen(for: window), active[screen.uuid] != nil else { continue }
            // A window brought here from another Space leaves that Space's tiles.
            for key in models.keys where !showing.contains(key) { models[key]!.remove(window.id) }
            add(window.id, on: screen.uuid)
            dirty.insert(screen.uuid)
        }

        for display in dirty { apply(display) }
        changed()
    }

    private func screen(for window: TrackedWindow) -> NSScreen? {
        guard let frame = window.element.frame else { return NSScreen.underPointer }
        return NSScreen.containing(axPoint: CGPoint(x: frame.midX, y: frame.midY))
    }

    private func add(_ id: WindowID, on display: String) {
        let activeTile = mru.lazy.compactMap { self.tiles(onDisplay: display)?.index(of: $0) }.first
        let outcome = edit(display) {
            $0.add(id, capacity: capacity(display), stackWhenFull: prefs.stackWhenFull, activeTile: activeTile)
        }
        if outcome == .full {
            floating.insert(id)
            overflow.append(id)
            center(id, on: display)
        }
    }

    private func remove(_ id: WindowID, from display: String, raiseNext: Bool = true) {
        assigned[id] = nil
        if cleanSpace?.window == id { cleanSpace = nil }
        let next = edit(display) { $0.remove(id) } ?? nil
        if raiseNext, let next { tracker.windows[next]?.element.perform(kAXRaiseAction) }
        fit(display)
    }

    /// Stacks or unstacks so a screen matches its window count, pulling in windows that floated
    /// because it was full. Returns whether anything moved.
    @discardableResult
    private func fit(_ display: String) -> Bool {
        let cap = capacity(display)
        let waiting = overflow.filter { id in
            tracker.windows[id].flatMap { screen(for: $0) }?.uuid == display
        }
        guard let key = active[display], var tiles = models[key] else { return false }
        let before = tiles.tiles.map(\.stack)
        tiles.trim(capacity: cap)
        tiles.fill(capacity: cap)
        // A waiting window comes back only if the screen can make room for it.
        var taken: [WindowID] = []
        for id in waiting {
            var trial = tiles
            guard trial.fill(capacity: cap, waiting: [id]) == [id], fits(trial, on: display) else { continue }
            tiles = trial
            taken.append(id)
        }
        models[key] = tiles
        for id in taken {
            overflow.removeAll { $0 == id }
            floating.remove(id)
        }
        return tiles.tiles.map(\.stack) != before
    }

    // MARK: Placing windows

    private func tree(for tiles: ScreenTiles, display: String, on screen: NSScreen) -> (LayoutNode, String) {
        let layout = prefs.layout(for: display)
        let n = max(1, tiles.tiles.count)
        let tree = Layout.tree(kind: layout.kind, count: n, mainRatio: prefs.mainSize.ratio, shape: screen.shape)
        return (tree, "\(layout.kind.rawValue)-\(n)")
    }

    private func appKey(_ id: WindowID) -> String? {
        tracker.windows[id].map { $0.bundleID ?? $0.appName }
    }

    private func fits(_ tiles: ScreenTiles, on display: String) -> Bool {
        guard let screen = NSScreen.with(uuid: display), !tiles.tiles.isEmpty else { return true }
        let (tree, key) = tree(for: tiles, display: display, on: screen)
        return Layout.constrain(tree, in: screen.axVisibleFrame, gap: gap,
                                weights: tiles.weights[key] ?? [:], mins: minimums(tiles)) != nil
    }

    /// The smallest size each tile can take, from what its apps have refused before.
    private func minimums(_ tiles: ScreenTiles) -> [Int: CGSize] {
        var out: [Int: CGSize] = [:]
        for (i, tile) in tiles.tiles.enumerated() {
            for id in tile.stack {
                guard let app = appKey(id), let m = prefs.minSizes[app] else { continue }
                let old = out[i] ?? .zero
                out[i] = CGSize(width: max(old.width, m.width), height: max(old.height, m.height))
            }
        }
        return out
    }

    /// Moves every window on a screen to its tile.
    func apply(_ display: String) {
        guard isActive, let key = active[display], let screen = NSScreen.with(uuid: display) else {
            changed()
            return
        }
        if let clean = cleanSpace, clean.screen == display, models[key]?.contains(clean.window) != true { cleanSpace = nil }
        let area = screen.axVisibleFrame

        // Split lines move to give apps the room they need. If they can't all fit,
        // the newest window with a known minimum floats until they do.
        var leaves: [Int: CGRect] = [:]
        while let tiles = models[key], !tiles.tiles.isEmpty {
            let (tree, weightKey) = tree(for: tiles, display: display, on: screen)
            let weights = tiles.weights[weightKey] ?? [:]
            if let fitted = Layout.constrain(tree, in: area, gap: gap, weights: weights, mins: minimums(tiles)) {
                leaves = Layout.rects(tree, in: area, gap: gap, weights: fitted).leaves
                break
            }
            guard let victim = tiles.tiles.reversed().flatMap({ $0.stack.reversed() })
                .first(where: { appKey($0).flatMap { prefs.minSizes[$0] } != nil }) else { break }
            models[key]!.remove(victim)
            floating.insert(victim)
            overflow.append(victim)
            center(victim, on: display)
        }
        guard let tiles = models[key], !tiles.tiles.isEmpty else {
            changed()
            return
        }

        let zoomed = cleanSpace?.screen == display ? cleanSpace?.window : tiles.zoomed
        let full = area.insetBy(dx: gap, dy: gap)
        var placed: [WindowID] = []
        for (i, tile) in tiles.tiles.enumerated() {
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

    private func place(_ id: WindowID, _ frame: CGRect, force: Bool = false) {
        guard let window = tracker.windows[id] else { return }
        assigned[id] = frame
        if !force, let current = window.element.frame,
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

    /// A window bigger than its tile gets put back twice more. Only if it holds the same size
    /// through all three tries (an app restoring its saved size or animating doesn't) does Windy
    /// learn the app's minimum and move the split lines to make room.
    private func checkFit(_ ids: [WindowID], attempt: Int = 1, seen: [WindowID: CGSize] = [:]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 1 ? 0.35 : 0.6)) { [weak self] in
            guard let self, NSEvent.pressedMouseButtons == 0 else { return }
            var sizes: [WindowID: CGSize] = [:]
            for id in ids where !dragged.contains(id) && isTooBig(id) {
                guard let size = tracker.windows[id]?.element.frame?.size else { continue }
                if let earlier = seen[id], abs(earlier.width - size.width) > 4 || abs(earlier.height - size.height) > 4 { continue }
                if attempt == 1 || seen[id] != nil { sizes[id] = size }
            }
            guard !sizes.isEmpty else { return }
            if attempt < 3 {
                for id in sizes.keys { if let frame = assigned[id] { place(id, frame, force: true) } }
                checkFit(Array(sizes.keys), attempt: attempt + 1, seen: sizes)
                return
            }
            var displays = Set<String>()
            for (id, size) in sizes {
                guard let target = assigned[id], let app = appKey(id), let (display, _) = locate(id),
                      let area = NSScreen.with(uuid: display)?.axVisibleFrame else { continue }
                // Never more than three quarters of the screen: past that, floating is the right answer anyway.
                let width = size.width > target.width + 8 ? min(size.width, area.width * 0.75) : 0
                let height = size.height > target.height + 8 ? min(size.height, area.height * 0.75) : 0
                prefs.learnMinSize(app, CGSize(width: width, height: height))
                displays.insert(display)
            }
            for display in displays { apply(display) }
        }
    }

    private func isTooBig(_ id: WindowID) -> Bool {
        guard let target = assigned[id], let actual = tracker.windows[id]?.element.frame,
              let (display, _) = locate(id), tiles(onDisplay: display)?.zoomed != id, cleanSpace?.window != id else { return false }
        return actual.width > target.width + 8 || actual.height > target.height + 8
    }

    private func center(_ id: WindowID, on display: String) {
        guard let window = tracker.windows[id], let screen = NSScreen.with(uuid: display),
              let frame = window.element.frame else { return }
        let area = screen.axVisibleFrame
        let size = CGSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
        ownChangeUntil[id] = Date().addingTimeInterval(0.6)
        window.element.setFrame(CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                                       width: size.width, height: size.height))
        assigned[id] = nil
    }

    func applyAll() {
        for display in active.keys { apply(display) }
    }

    func forgetMinSizes() {
        prefs.minSizes = [:]
        applyAll()
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

        if let (display, i) = locate(id) {
            let zoomedOther = edit(display) { s -> Bool in
                s.tiles[i].top = id
                // Clicking another window on a zoomed screen goes back to the layout.
                guard let z = s.zoomed, z != id else { return false }
                s.zoomed = nil
                return true
            } ?? false
            if zoomedOther { apply(display) }
            // Clean Space shows whichever window you bring forward on that screen.
            if let clean = cleanSpace, clean.screen == display, clean.window != id {
                cleanSpace = (display, id)
                apply(display)
            }
        }
        changed()
    }

    func focus(_ id: WindowID) {
        tracker.windows[id]?.focus()
    }

    // MARK: User moving and resizing windows

    func geometryChanged(_ id: WindowID) {
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
            if let (display, _) = locate(id) { apply(display) }
        }
    }

    /// Called on every left mouse-up. Finishes drags: resize, swap, stack, move to another screen, or snap back.
    func mouseUp(modifiers: NSEvent.ModifierFlags) {
        let ids = dragged
        dragged.removeAll()
        for id in ids { finishDrag(id, modifiers: modifiers) }
    }

    private func finishDrag(_ id: WindowID, modifiers: NSEvent.ModifierFlags) {
        guard let window = tracker.windows[id], let frame = window.element.frame,
              let (display, i) = locate(id), let old = assigned[id], let tiles = tiles(onDisplay: display) else { return }

        let resized = abs(frame.width - old.width) > 2 || abs(frame.height - old.height) > 2
        if resized {
            if tiles.zoomed == nil, cleanSpace?.window != id, let screen = NSScreen.with(uuid: display) {
                let (tree, key) = tree(for: tiles, display: display, on: screen)
                let weights = Layout.fit(i, to: frame, tree: tree, in: screen.axVisibleFrame, gap: gap,
                                         weights: tiles.weights[key] ?? [:])
                edit(display) { $0.weights[key] = weights }
            }
            apply(display)
            return
        }

        let point = flippedPoint(NSEvent.mouseLocation)
        guard let screen = NSScreen.containing(axPoint: point), let target = self.tiles(onDisplay: screen.uuid) else {
            apply(display)
            return
        }
        let other = screen.uuid
        let targetTile = target.tiles.indices.first { j in
            !(other == display && j == i) && (assigned[target.tiles[j].top]?.contains(point) ?? false)
        }

        if modifiers.contains(.command), let j = targetTile {
            if modifiers.contains(.option) {
                addToStack(id, from: display, onto: target.tiles[j].top)
            } else {
                swapTiles(display, i, other, j)
            }
        } else if other != display {
            moveToNewTile(id, from: display, to: other)
        }
        apply(display)
        if other != display { apply(other) }
    }

    private func swapTiles(_ a: String, _ i: Int, _ b: String, _ j: Int) {
        guard let ka = active[a], let kb = active[b] else { return }
        if ka == kb {
            models[ka]!.tiles.swapAt(i, j)
        } else {
            let t = models[ka]!.tiles[i]
            models[ka]!.tiles[i] = models[kb]!.tiles[j]
            models[kb]!.tiles[j] = t
            // A zoomed window that left its screen ends its zoom.
            for k in [ka, kb] where models[k]!.zoomed.map({ !models[k]!.contains($0) }) == true { models[k]!.zoomed = nil }
        }
    }

    @discardableResult
    private func moveToNewTile(_ id: WindowID, from display: String, to target: String) -> Bool {
        guard let count = tiles(onDisplay: target)?.tiles.count, count < capacity(target) else { return false }
        remove(id, from: display)
        edit(target) { $0.tiles.append(Tile(id)) }
        return true
    }

    private func addToStack(_ id: WindowID, from display: String, onto top: WindowID) {
        remove(id, from: display)
        guard let (target, _) = locate(top) else { return }
        edit(target) { $0.push(id, onto: top) }
    }

    // MARK: Commands

    private var focusedLocation: (display: String, tile: Int)? {
        focused.flatMap { locate($0) }
    }

    /// The screen commands act on: the active window's, or the one under the pointer.
    var currentScreenUUID: String? {
        focusedLocation?.display ?? NSScreen.underPointer?.uuid
    }

    func toggleFocusMode(_ window: WindowID? = nil) {
        guard let id = window ?? focused, let (display, _) = locate(id) else { return }
        edit(display) { $0.zoomed = $0.zoomed == id ? nil : id }
        apply(display)
    }

    func toggleCleanSpace(_ window: WindowID? = nil) {
        if let clean = cleanSpace {
            cleanSpace = nil
            apply(clean.screen)
            return
        }
        guard let id = window ?? focused, let (display, _) = locate(id) else { return }
        cleanSpace = (display, id)
        apply(display)
    }

    func endCleanSpace() {
        guard let clean = cleanSpace else { return }
        cleanSpace = nil
        apply(clean.screen)
    }

    func cycleStack(_ step: Int) {
        guard let id = focused, let (display, _) = locate(id),
              let next = edit(display, { $0.cycle(from: id, step: step) }) ?? nil else { return }
        focus(next)
    }

    private func tileRects(_ display: String) -> [Int: CGRect] {
        var out: [Int: CGRect] = [:]
        for (i, tile) in (tiles(onDisplay: display)?.tiles ?? []).enumerated() { out[i] = assigned[tile.top] }
        return out
    }

    /// Swaps with the neighbor that way, or moves to the next screen past the edge.
    func swap(_ direction: Direction, window: WindowID? = nil) {
        guard let id = window ?? focused, let (display, i) = locate(id), let screen = NSScreen.with(uuid: display) else { return }
        let rects = tileRects(display)
        if let origin = rects[i], let j = Layout.neighbor(of: origin, in: rects, direction: direction) {
            swapTiles(display, i, display, j)
            apply(display)
            return
        }
        guard let next = screen.neighbor(direction), active[next.uuid] != nil else { return }
        let target = next.uuid
        if !moveToNewTile(id, from: display, to: target) {
            // Full screen: trade places with the tile nearest to where the window comes in.
            let origin = assigned[id] ?? .zero
            guard let j = tileRects(target).min(by: {
                hypot($0.value.midX - origin.midX, $0.value.midY - origin.midY)
                    < hypot($1.value.midX - origin.midX, $1.value.midY - origin.midY)
            })?.key else { return }
            swapTiles(display, i, target, j)
        }
        apply(display)
        apply(target)
        focus(id)
    }

    func makePrimary(_ window: WindowID? = nil) {
        guard let (display, i) = (window ?? focused).flatMap({ locate($0) }), i != 0 else { return }
        swapTiles(display, 0, display, i)
        apply(display)
    }

    func resize(by delta: Double) {
        guard let (display, i) = focusedLocation, let tiles = tiles(onDisplay: display), tiles.zoomed == nil,
              let screen = NSScreen.with(uuid: display) else { return }
        let (tree, key) = tree(for: tiles, display: display, on: screen)
        let before = tiles.weights[key] ?? [:]
        let after = Layout.grow(i, by: delta, tree: tree, weights: before)
        if after == before { NSSound.beep() }
        edit(display) { $0.weights[key] = after }
        apply(display)
    }

    func resetSizes(_ uuid: String? = nil) {
        guard let display = uuid ?? currentScreenUUID else { return }
        edit(display) { $0.weights.removeAll() }
        apply(display)
    }

    func focusNeighbor(_ step: Int) {
        guard let (display, i) = focusedLocation, let tiles = tiles(onDisplay: display)?.tiles, tiles.count > 1 else { return }
        focus(tiles[((i + step) % tiles.count + tiles.count) % tiles.count].top)
    }

    func toggleFloat(_ window: WindowID? = nil) {
        guard let id = window ?? focused else { return }
        overflow.removeAll { $0 == id }
        if floating.contains(id) {
            floating.remove(id)
            reconcile()
        } else if let (display, _) = locate(id) {
            remove(id, from: display)
            floating.insert(id)
            center(id, on: display)
            apply(display)
        }
    }

    /// Changes a screen's layout or window count, stacking or unstacking windows to fit.
    func setLayout(kind: LayoutKind? = nil, count: Int? = nil, screen uuid: String? = nil) {
        guard let display = uuid ?? currentScreenUUID else { return }
        var layout = prefs.layout(for: display)
        if let kind { layout.kind = kind }
        if let count { layout.count = min(5, max(1, count)) }
        prefs.screenLayouts[display] = layout
        fit(display)
        apply(display)
    }

    /// Gives `windows` the first tiles of a screen, in order. Windows from other screens move over;
    /// floating ones tile again. Returns the windows that couldn't be placed (minimized, hidden, excluded).
    @discardableResult
    func arrange(_ windows: [WindowID], on display: String, kind: LayoutKind? = nil, count: Int? = nil) -> [WindowID] {
        reconcile()
        var layout = prefs.layout(for: display)
        if let kind { layout.kind = kind }
        if let count { layout.count = min(5, max(1, count)) }
        prefs.screenLayouts[display] = layout
        guard active[display] != nil else { return windows }

        let tileable = Set(tracker.visibleWindows().filter { !prefs.isExcluded($0.bundleID) }.map(\.id))
        var missing: [WindowID] = []
        var touched: Set<String> = [display]
        for id in windows {
            guard tileable.contains(id) else { missing.append(id); continue }
            floating.remove(id)
            overflow.removeAll { $0 == id }
            if let (other, _) = locate(id), other != display {
                remove(id, from: other, raiseNext: false)
                touched.insert(other)
            }
            if tiles(onDisplay: display)?.contains(id) != true { edit(display) { $0.tiles.append(Tile(id)) } }
        }
        let cap = capacity(display)
        edit(display) { $0.arrange(windows, capacity: cap) }
        fit(display)
        for d in touched { apply(d) }
        return missing
    }

    // MARK: Focus follows mouse

    private var hoverWork: DispatchWorkItem?

    func hover(at point: CGPoint) {
        hoverWork?.cancel()
        guard prefs.focusFollowsMouse, isActive, NSEvent.pressedMouseButtons == 0 else { return }
        guard let screen = NSScreen.containing(axPoint: point), let tiles = tiles(onDisplay: screen.uuid),
              tiles.zoomed == nil, cleanSpace?.screen != screen.uuid else { return }
        // Only the window actually under the pointer, and only if it's a tile's top window.
        guard let target = Self.topWindow(at: point), tiles.tiles.contains(where: { $0.top == target }),
              target != focused else { return }
        let work = DispatchWorkItem { [weak self] in self?.focus(target) }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// The frontmost normal window containing an AX point (CG window bounds share AX coordinates).
    static func topWindow(at point: CGPoint) -> WindowID? {
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
