public typealias WindowID = UInt32

/// One place in a layout. It can hold a stack of windows that share its frame; `top` is the one showing.
public struct Tile: Equatable, Sendable {
    public var stack: [WindowID]
    public var top: WindowID

    public init(_ id: WindowID) {
        stack = [id]
        top = id
    }
}

public enum AddOutcome: Equatable, Sendable {
    case tiled, stacked, full
}

/// The tiles of one display on one Space, in the order their windows arrived.
/// Pure state: Windy's tiler turns it into window frames.
public struct ScreenTiles: Equatable, Sendable {
    public var tiles: [Tile] = []
    /// Sizes the user set by dragging or with ⌃⌥=/-, per layout and tile count.
    public var weights: [String: SplitWeights] = [:]
    /// The window zoomed by focus mode, if any.
    public var zoomed: WindowID?

    public init() {}

    public var windows: [WindowID] { tiles.flatMap(\.stack) }
    public var windowCount: Int { tiles.reduce(0) { $0 + $1.stack.count } }
    public func index(of id: WindowID) -> Int? { tiles.firstIndex { $0.stack.contains(id) } }
    public func contains(_ id: WindowID) -> Bool { index(of: id) != nil }

    /// A new window gets its own tile while there's room. When the screen is full it goes on top of
    /// `activeTile` (or the last tile) if stacking is on; otherwise it doesn't fit.
    public mutating func add(_ id: WindowID, capacity: Int, stackWhenFull: Bool, activeTile: Int?) -> AddOutcome {
        if tiles.count < capacity {
            tiles.append(Tile(id))
            return .tiled
        }
        guard stackWhenFull, !tiles.isEmpty else { return .full }
        let i = activeTile.flatMap { tiles.indices.contains($0) ? $0 : nil } ?? tiles.count - 1
        tiles[i].stack.append(id)
        tiles[i].top = id
        return .stacked
    }

    /// Takes a window out. If it was showing in a stack, returns the window that now shows instead.
    /// An emptied tile is removed; call `fill` afterwards to use the freed room.
    @discardableResult
    public mutating func remove(_ id: WindowID) -> WindowID? {
        if zoomed == id { zoomed = nil }
        guard let i = index(of: id) else { return nil }
        tiles[i].stack.removeAll { $0 == id }
        if tiles[i].stack.isEmpty {
            tiles.remove(at: i)
            return nil
        }
        guard tiles[i].top == id else { return nil }
        tiles[i].top = tiles[i].stack.last!
        return tiles[i].top
    }

    /// Gives free tiles to windows waiting in stacks, then to `waiting` windows in order.
    /// Returns the waiting windows that got a tile.
    @discardableResult
    public mutating func fill(capacity: Int, waiting: [WindowID] = []) -> [WindowID] {
        while tiles.count < capacity, let j = tiles.lastIndex(where: { $0.stack.count > 1 }) {
            let top = tiles[j].top
            let next = tiles[j].stack.first { $0 != top }!
            tiles[j].stack.removeAll { $0 == next }
            tiles.append(Tile(next))
        }
        var taken: [WindowID] = []
        for id in waiting where tiles.count < capacity && !contains(id) {
            tiles.append(Tile(id))
            taken.append(id)
        }
        return taken
    }

    /// Stacks tiles beyond `capacity` underneath the last tile that stays.
    public mutating func trim(capacity: Int) {
        let cap = max(1, capacity)
        while tiles.count > cap {
            let extra = tiles.removeLast()
            tiles[tiles.count - 1].stack.insert(contentsOf: extra.stack, at: 0)
        }
    }

    /// Native tabs and similar: a new window ID takes over another's place.
    public mutating func replace(_ old: WindowID, with new: WindowID) {
        guard let i = index(of: old) else { return }
        tiles[i].stack = tiles[i].stack.map { $0 == old ? new : $0 }
        if tiles[i].top == old { tiles[i].top = new }
        if zoomed == old { zoomed = new }
    }

    /// Puts a window on top of the stack that holds `top`.
    public mutating func push(_ id: WindowID, onto top: WindowID) {
        guard let i = index(of: top) else { return }
        tiles[i].stack.append(id)
        tiles[i].top = id
    }

    /// Shows the next (or previous) window of the stack holding `id`. Returns it.
    public mutating func cycle(from id: WindowID, step: Int) -> WindowID? {
        guard let i = index(of: id), tiles[i].stack.count > 1 else { return nil }
        let stack = tiles[i].stack
        let k = stack.firstIndex(of: tiles[i].top) ?? 0
        tiles[i].top = stack[((k + step) % stack.count + stack.count) % stack.count]
        return tiles[i].top
    }

    /// Gives `order` the first tiles, one each, in that order. Every other window on the screen
    /// follows in its current order, and anything past `capacity` stacks under the last tile.
    /// Windows in `order` that aren't on this screen are ignored.
    public mutating func arrange(_ order: [WindowID], capacity: Int) {
        let chosen = order.filter { contains($0) }
        guard !chosen.isEmpty else { return }
        var rest: [Tile] = []
        for var tile in tiles {
            tile.stack.removeAll { chosen.contains($0) }
            guard !tile.stack.isEmpty else { continue }
            if chosen.contains(tile.top) { tile.top = tile.stack.last! }
            rest.append(tile)
        }
        tiles = chosen.map(Tile.init) + rest
        trim(capacity: capacity)
        if let z = zoomed, !contains(z) { zoomed = nil }
    }
}
