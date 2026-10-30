import CoreGraphics
import Testing
@testable import WindyCore

private let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)

private func frames(_ kind: LayoutKind, _ count: Int, ratio: Double? = nil, shape: ScreenShape = .normal,
                    gap: CGFloat = 0, weights: SplitWeights = [:]) -> [Int: CGRect] {
    let tree = Layout.tree(kind: kind, count: count, mainRatio: ratio, shape: shape)
    return Layout.rects(tree, in: screen, gap: gap, weights: weights).leaves
}

@Test func gridFoldOneToFour() {
    #expect(frames(.grid, 1)[0] == screen)

    let two = frames(.grid, 2)
    #expect(two[0] == CGRect(x: 0, y: 0, width: 500, height: 600))
    #expect(two[1] == CGRect(x: 500, y: 0, width: 500, height: 600))

    let three = frames(.grid, 3)
    #expect(three[0] == CGRect(x: 0, y: 0, width: 500, height: 600))
    #expect(three[1] == CGRect(x: 500, y: 0, width: 500, height: 300))
    #expect(three[2] == CGRect(x: 500, y: 300, width: 500, height: 300))

    // Primary top-left, 2 top-right, 3 bottom-right, 4 bottom-left.
    let four = frames(.grid, 4)
    #expect(four[0] == CGRect(x: 0, y: 0, width: 500, height: 300))
    #expect(four[1] == CGRect(x: 500, y: 0, width: 500, height: 300))
    #expect(four[2] == CGRect(x: 500, y: 300, width: 500, height: 300))
    #expect(four[3] == CGRect(x: 0, y: 300, width: 500, height: 300))
}

@Test func columnsRowsAndMainRatio() {
    let cols = frames(.columns, 4)
    #expect(cols.values.allSatisfy { $0.width == 250 && $0.height == 600 })

    let rows = frames(.rows, 3, ratio: 0.6)
    #expect(rows[0]?.height == 360)
    #expect(rows[1]?.height == 120)

    let side = frames(.side, 4, ratio: 2.0 / 3.0)
    #expect(side[0]?.width == 667)
    #expect(side[1] == CGRect(x: 667, y: 0, width: 333, height: 200))
}

@Test func gapsSurroundAndSeparate() {
    let two = frames(.grid, 2, gap: 10)
    #expect(two[0] == CGRect(x: 10, y: 10, width: 485, height: 580))
    #expect(two[1] == CGRect(x: 505, y: 10, width: 485, height: 580))
}

@Test func capacityAndScreenShapes() {
    #expect(Layout.capacity(.grid, shape: .ultrawide) == 4)
    #expect(Layout.capacity(.side, shape: .ultrawide) == 5)
    #expect(Layout.capacity(.side, shape: .vertical) == 5)
    #expect(ScreenShape(size: CGSize(width: 3440, height: 1440)) == .ultrawide)
    #expect(ScreenShape(size: CGSize(width: 1080, height: 1920)) == .vertical)

    // Vertical monitors put the primary on top.
    let tree = Layout.tree(kind: .grid, count: 2, mainRatio: nil, shape: .vertical)
    let r = Layout.rects(tree, in: CGRect(x: 0, y: 0, width: 600, height: 1000), gap: 0).leaves
    #expect(r[0] == CGRect(x: 0, y: 0, width: 600, height: 500))

    // Ultrawide Side: two big windows and a narrow column.
    let wide = Layout.rects(Layout.tree(kind: .side, count: 5, mainRatio: nil, shape: .ultrawide),
                            in: CGRect(x: 0, y: 0, width: 3000, height: 1000), gap: 0).leaves
    #expect(wide[0]?.width == 1200)
    #expect(wide[1]?.width == 1200)
    #expect(wide[4] == CGRect(x: 2400, y: 667, width: 600, height: 333))
}

@Test func growAndShrink() {
    let tree = Layout.tree(kind: .grid, count: 3, mainRatio: nil, shape: .normal)
    let grown = Layout.grow(1, by: 0.1, tree: tree, weights: [:])
    let r = Layout.rects(tree, in: screen, gap: 0, weights: grown).leaves
    #expect(r[1] == CGRect(x: 400, y: 0, width: 600, height: 360))
    #expect(r[0]?.width == 400)

    // Never smaller than the minimum.
    var w: SplitWeights = [:]
    for _ in 0..<20 { w = Layout.grow(0, by: -0.1, tree: tree, weights: w) }
    #expect(abs(w["r"]![0] - Layout.minWeight) < 0.0001)
}

@Test func fitFollowsDraggedSharedEdgesOnly() {
    let tree = Layout.tree(kind: .grid, count: 3, mainRatio: nil, shape: .normal)
    // Window 1 (top right) dragged its left edge to x=600 and bottom edge to y=400.
    let w = Layout.fit(1, to: CGRect(x: 600, y: 0, width: 400, height: 400), tree: tree, in: screen, gap: 0, weights: [:])
    let r = Layout.rects(tree, in: screen, gap: 0, weights: w).leaves
    #expect(r[0]?.width == 600)
    #expect(r[1] == CGRect(x: 600, y: 0, width: 400, height: 400))
    #expect(r[2] == CGRect(x: 600, y: 400, width: 400, height: 200))

    // Dragging the outer (screen) edge changes nothing.
    let same = Layout.fit(0, to: CGRect(x: 50, y: 0, width: 450, height: 600), tree: tree, in: screen, gap: 0, weights: [:])
    #expect(same.isEmpty)
}

@Test func neighborPrefersTopOfColumn() {
    let three = frames(.grid, 3)
    #expect(Layout.neighbor(of: three[0]!, in: three, direction: .right) == 1)
    #expect(Layout.neighbor(of: three[2]!, in: three, direction: .left) == 0)
    #expect(Layout.neighbor(of: three[1]!, in: three, direction: .down) == 2)
    #expect(Layout.neighbor(of: three[0]!, in: three, direction: .left) == nil)
}
