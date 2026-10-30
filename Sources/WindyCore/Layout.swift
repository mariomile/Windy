import CoreGraphics

/// How a screen arranges its tiles.
public enum LayoutKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case grid, columns, rows, side

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .grid: "Grid"
        case .columns: "Columns"
        case .rows: "Rows"
        case .side: "Side"
        }
    }
}

public enum Axis: Sendable, Equatable {
    case horizontal, vertical
    var flipped: Axis { self == .horizontal ? .vertical : .horizontal }
}

public enum Direction: Sendable, CaseIterable {
    case left, right, up, down
}

public enum ScreenShape: Sendable, Equatable {
    case normal, ultrawide, vertical

    public init(size: CGSize) {
        if size.height > size.width {
            self = .vertical
        } else if size.width >= size.height * 2.1 {
            self = .ultrawide
        } else {
            self = .normal
        }
    }
}

/// A layout is a tree of splits. Leaves are tile indexes, in the order windows arrived.
public indirect enum LayoutNode: Sendable, Equatable {
    case leaf(Int)
    case split(Axis, [LayoutNode], [Double])

    func flipped() -> LayoutNode {
        switch self {
        case .leaf: self
        case let .split(axis, kids, weights): .split(axis.flipped, kids.map { $0.flipped() }, weights)
        }
    }
}

/// Custom split weights, keyed by node path ("r", "r.0", "r.1.0", ...).
public typealias SplitWeights = [String: [Double]]

public struct Ancestor: Sendable, Equatable {
    public let path: String
    public let axis: Axis
    public let child: Int
    public let count: Int
    public let defaults: [Double]
}

public enum Layout {
    public static let minWeight = 0.1
    public static let minExtent: CGFloat = 120

    /// How many tiles a screen can hold for a layout.
    public static func capacity(_ kind: LayoutKind, shape: ScreenShape) -> Int {
        kind == .side && shape != .normal ? 5 : 4
    }

    /// Builds the split tree for `count` tiles.
    /// Grid follows the fold: each new window takes half of the newest space,
    /// and four windows make a 2×2 grid where the primary gives up the bottom of its column.
    public static func tree(kind: LayoutKind, count: Int, mainRatio: Double?, shape: ScreenShape) -> LayoutNode {
        let n = max(1, count)
        guard n > 1 else { return .leaf(0) }
        let pair = mainWeights(mainRatio, 2)
        func column(_ range: Range<Int>) -> LayoutNode {
            range.count == 1 ? .leaf(range.lowerBound)
                : .split(.vertical, range.map(LayoutNode.leaf), Array(repeating: 1, count: range.count))
        }

        switch kind {
        case .grid:
            let node: LayoutNode
            switch n {
            case 2: node = .split(.horizontal, [.leaf(0), .leaf(1)], pair)
            case 3: node = .split(.horizontal, [.leaf(0), column(1..<3)], pair)
            default:
                node = .split(.horizontal, [
                    .split(.vertical, [.leaf(0), .leaf(3)], [1, 1]),
                    .split(.vertical, [.leaf(1), .leaf(2)], [1, 1]),
                ], pair)
            }
            return shape == .vertical ? node.flipped() : node
        case .columns:
            return .split(.horizontal, (0..<n).map(LayoutNode.leaf), mainWeights(mainRatio, n))
        case .rows:
            return .split(.vertical, (0..<n).map(LayoutNode.leaf), mainWeights(mainRatio, n))
        case .side:
            if shape == .ultrawide && n >= 3 {
                // Two big windows and a narrow column for the rest.
                let weights = mainRatio.map { [$0, (1 - $0) * 0.65, (1 - $0) * 0.35] } ?? [0.4, 0.4, 0.2]
                return .split(.horizontal, [.leaf(0), .leaf(1), column(2..<n)], weights)
            }
            let node = LayoutNode.split(.horizontal, [.leaf(0), column(1..<n)], pair)
            return shape == .vertical ? node.flipped() : node
        }
    }

    static func mainWeights(_ ratio: Double?, _ n: Int) -> [Double] {
        guard let ratio, n > 1 else { return Array(repeating: 1, count: n) }
        return [ratio] + Array(repeating: (1 - ratio) / Double(n - 1), count: n - 1)
    }

    static func normalized(_ w: [Double]) -> [Double] {
        let sum = w.reduce(0, +)
        guard sum > 0 else { return Array(repeating: 1 / Double(w.count), count: w.count) }
        return w.map { $0 / sum }
    }

    /// Frames for every leaf and every node. `rect` is the usable screen area; `gap` is used
    /// both between tiles and around the edge.
    public static func rects(
        _ tree: LayoutNode, in rect: CGRect, gap: CGFloat, weights: SplitWeights = [:]
    ) -> (leaves: [Int: CGRect], nodes: [String: CGRect]) {
        var leaves: [Int: CGRect] = [:]
        var nodes: [String: CGRect] = [:]

        func walk(_ node: LayoutNode, _ r: CGRect, _ path: String) {
            nodes[path] = r
            switch node {
            case let .leaf(i):
                leaves[i] = CGRect(x: r.minX.rounded(), y: r.minY.rounded(),
                                   width: r.width.rounded(), height: r.height.rounded())
            case let .split(axis, kids, defaults):
                let custom = weights[path].flatMap { $0.count == kids.count ? $0 : nil }
                let w = normalized(custom ?? defaults)
                let total = axis == .horizontal ? r.width : r.height
                let available = max(0, total - gap * CGFloat(kids.count - 1))
                var offset: CGFloat = 0
                for (i, kid) in kids.enumerated() {
                    let length = available * CGFloat(w[i])
                    let kr = axis == .horizontal
                        ? CGRect(x: r.minX + offset, y: r.minY, width: length, height: r.height)
                        : CGRect(x: r.minX, y: r.minY + offset, width: r.width, height: length)
                    walk(kid, kr, "\(path).\(i)")
                    offset += length + gap
                }
            }
        }

        walk(tree, rect.insetBy(dx: gap, dy: gap), "r")
        return (leaves, nodes)
    }

    /// Moves split lines so every tile is at least as big as `mins` asks, taking the room from
    /// neighbors that have some to spare. Returns nil when the screen can't fit them all.
    public static func constrain(
        _ tree: LayoutNode, in rect: CGRect, gap: CGFloat, weights: SplitWeights, mins: [Int: CGSize]
    ) -> SplitWeights? {
        guard !mins.isEmpty else { return weights }

        func minExtent(_ node: LayoutNode, _ axis: Axis) -> CGFloat {
            switch node {
            case let .leaf(i):
                let m = mins[i] ?? .zero
                return axis == .horizontal ? m.width : m.height
            case let .split(a, kids, _):
                let each = kids.map { minExtent($0, axis) }
                return a == axis ? each.reduce(0, +) + gap * CGFloat(kids.count - 1) : (each.max() ?? 0)
            }
        }

        var out = weights
        var feasible = true

        func walk(_ node: LayoutNode, _ r: CGRect, _ path: String) {
            guard feasible, case let .split(axis, kids, defaults) = node else { return }
            let horizontal = axis == .horizontal
            let available = max(0, (horizontal ? r.width : r.height) - gap * CGFloat(kids.count - 1))
            let custom = out[path].flatMap { $0.count == kids.count ? $0 : nil }
            var extents = normalized(custom ?? defaults).map { available * CGFloat($0) }
            let needs = kids.map { minExtent($0, axis) }
            let across = horizontal ? r.height : r.width
            guard needs.reduce(0, +) <= available + 0.5,
                  kids.allSatisfy({ minExtent($0, axis.flipped) <= across + 0.5 }) else {
                feasible = false
                return
            }

            let deficit = zip(extents, needs).reduce(0) { $0 + max(0, $1.1 - $1.0) }
            if deficit > 0.5 {
                for i in extents.indices where extents[i] < needs[i] { extents[i] = needs[i] }
                let slack = extents.indices.map { max(0, extents[$0] - needs[$0]) }
                let totalSlack = slack.reduce(0, +)
                for i in extents.indices where totalSlack > 0 { extents[i] -= deficit * slack[i] / totalSlack }
                out[path] = normalized(extents.map(Double.init))
            }

            var offset: CGFloat = 0
            for (i, kid) in kids.enumerated() {
                let kr = horizontal
                    ? CGRect(x: r.minX + offset, y: r.minY, width: extents[i], height: r.height)
                    : CGRect(x: r.minX, y: r.minY + offset, width: r.width, height: extents[i])
                walk(kid, kr, "\(path).\(i)")
                offset += extents[i] + gap
            }
        }

        walk(tree, rect.insetBy(dx: gap, dy: gap), "r")
        return feasible ? out : nil
    }

    /// The split nodes above a leaf, outermost first.
    public static func ancestors(of index: Int, in tree: LayoutNode) -> [Ancestor] {
        func search(_ node: LayoutNode, _ path: String) -> [Ancestor]? {
            switch node {
            case let .leaf(i):
                return i == index ? [] : nil
            case let .split(axis, kids, defaults):
                for (c, kid) in kids.enumerated() {
                    if let rest = search(kid, "\(path).\(c)") {
                        return [Ancestor(path: path, axis: axis, child: c, count: kids.count, defaults: defaults)] + rest
                    }
                }
                return nil
            }
        }
        return search(tree, "r") ?? []
    }

    /// Makes a tile bigger (positive delta) or smaller along every split it belongs to.
    public static func grow(_ index: Int, by delta: Double, tree: LayoutNode, weights: SplitWeights) -> SplitWeights {
        var out = weights
        for a in ancestors(of: index, in: tree) {
            var w = normalized(out[a.path].flatMap { $0.count == a.count ? $0 : nil } ?? a.defaults)
            let others = 1 - w[a.child]
            let maxSelf = 1 - minWeight * Double(a.count - 1)
            let target = min(maxSelf, max(minWeight, w[a.child] + delta))
            let newOthers = 1 - target
            for i in w.indices where i != a.child {
                w[i] = others > 0 ? w[i] / others * newOthers : newOthers / Double(a.count - 1)
            }
            w[a.child] = target
            out[a.path] = w
        }
        return out
    }

    /// Updates weights after the user dragged a tile's edges so the tile matches `frame`.
    /// Only edges shared with a neighbor move; outer edges are ignored.
    public static func fit(
        _ index: Int, to frame: CGRect, tree: LayoutNode, in rect: CGRect, gap: CGFloat, weights: SplitWeights
    ) -> SplitWeights {
        let (leaves, nodes) = rects(tree, in: rect, gap: gap, weights: weights)
        guard let old = leaves[index] else { return weights }
        var out = weights

        for a in ancestors(of: index, in: tree) {
            let kids = (0..<a.count).compactMap { nodes["\(a.path).\($0)"] }
            guard kids.count == a.count else { continue }
            let horizontal = a.axis == .horizontal
            func lo(_ r: CGRect) -> CGFloat { horizontal ? r.minX : r.minY }
            func hi(_ r: CGRect) -> CGFloat { horizontal ? r.maxX : r.maxY }
            var extents = kids.map { hi($0) - lo($0) }
            let k = a.child
            var changed = false

            // Move `amount` of space from extents[from] to extents[to], keeping both usable.
            func shift(from: Int, to: Int, _ amount: CGFloat) {
                let clamped = min(extents[from] - minExtent, max(-(extents[to] - minExtent), amount))
                guard abs(clamped) >= 1 else { return }
                extents[from] -= clamped
                extents[to] += clamped
                changed = true
            }

            if k > 0, abs(lo(old) - lo(kids[k])) < 2 {
                shift(from: k, to: k - 1, lo(frame) - lo(old))
            }
            if k < a.count - 1, abs(hi(old) - hi(kids[k])) < 2 {
                shift(from: k + 1, to: k, hi(frame) - hi(old))
            }
            if changed { out[a.path] = normalized(extents.map(Double.init)) }
        }
        return out
    }

    /// The closest rect in `direction` from `origin` that overlaps it on the other axis.
    /// Ties go to the topmost, then leftmost, candidate.
    public static func neighbor(of origin: CGRect, in candidates: [Int: CGRect], direction: Direction) -> Int? {
        var best: (index: Int, distance: CGFloat, y: CGFloat, x: CGFloat)?
        for (i, r) in candidates where r != origin {
            let distance: CGFloat
            let overlaps: Bool
            switch direction {
            case .right:
                distance = r.minX - origin.maxX
                overlaps = r.minY < origin.maxY - 1 && r.maxY > origin.minY + 1
            case .left:
                distance = origin.minX - r.maxX
                overlaps = r.minY < origin.maxY - 1 && r.maxY > origin.minY + 1
            case .down:
                distance = r.minY - origin.maxY
                overlaps = r.minX < origin.maxX - 1 && r.maxX > origin.minX + 1
            case .up:
                distance = origin.minY - r.maxY
                overlaps = r.minX < origin.maxX - 1 && r.maxX > origin.minX + 1
            }
            guard overlaps, distance > -2 else { continue }
            if let b = best {
                if distance > b.distance + 1 { continue }
                if abs(distance - b.distance) <= 1 && (r.minY, r.minX) >= (b.y, b.x) { continue }
            }
            best = (i, distance, r.minY, r.minX)
        }
        return best?.index
    }
}
