import CoreGraphics
import Foundation
import Testing
@testable import WindyCore

private func screen(_ ids: [WindowID], capacity: Int = 4) -> ScreenTiles {
    var s = ScreenTiles()
    for id in ids { _ = s.add(id, capacity: capacity, stackWhenFull: true, activeTile: nil) }
    return s
}

@Test func addTilesThenStacksOnActiveTile() {
    var s = screen([1, 2, 3, 4])
    #expect(s.tiles.map(\.top) == [1, 2, 3, 4])
    #expect(s.add(5, capacity: 4, stackWhenFull: true, activeTile: 1) == .stacked)
    #expect(s.tiles[1].stack == [2, 5])
    #expect(s.tiles[1].top == 5)
    #expect(s.add(6, capacity: 4, stackWhenFull: false, activeTile: 1) == .full)
    #expect(!s.contains(6))
}

@Test func removingTheTopShowsTheNextAndEmptyTilesGo() {
    var s = screen([1, 2])
    _ = s.add(3, capacity: 2, stackWhenFull: true, activeTile: 0)
    #expect(s.remove(3) == 1)
    #expect(s.tiles[0].top == 1)
    #expect(s.remove(2) == nil)
    #expect(s.tiles.count == 1)
}

@Test func fillUnstacksThenTakesWaitingWindows() {
    var s = screen([1, 2], capacity: 2)
    _ = s.add(3, capacity: 2, stackWhenFull: true, activeTile: 0)
    s.remove(2)
    #expect(s.fill(capacity: 4, waiting: [9, 10, 11]) == [9, 10])
    #expect(s.tiles.map(\.top) == [3, 1, 9, 10])
}

@Test func trimStacksExtrasUnderTheLastKeptTile() {
    var s = screen([1, 2, 3, 4])
    s.trim(capacity: 2)
    #expect(s.tiles.count == 2)
    #expect(s.tiles[1].stack == [4, 3, 2])
    #expect(s.tiles[1].top == 2)
    s.fill(capacity: 4)
    #expect(s.tiles.count == 4)
    #expect(Set(s.windows) == [1, 2, 3, 4])
}

@Test func replaceKeepsTheSlotAndZoom() {
    var s = screen([1, 2, 3])
    s.zoomed = 2
    s.replace(2, with: 7)
    #expect(s.tiles[1].top == 7)
    #expect(s.zoomed == 7)
}

@Test func removingTheZoomedWindowEndsZoom() {
    var s = screen([1, 2])
    s.zoomed = 2
    s.remove(2)
    #expect(s.zoomed == nil)
}

@Test func cycleWrapsBothWays() {
    var s = screen([1], capacity: 1)
    _ = s.add(2, capacity: 1, stackWhenFull: true, activeTile: 0)
    _ = s.add(3, capacity: 1, stackWhenFull: true, activeTile: 0)
    #expect(s.cycle(from: 3, step: 1) == 1)
    #expect(s.cycle(from: 1, step: -1) == 3)
}

@Test func arrangePutsChosenFirstAndStacksTheRest() {
    var s = screen([1, 2, 3, 4])
    s.arrange([3, 1], capacity: 2)
    #expect(s.tiles.count == 2)
    #expect(s.tiles[0].top == 3)
    #expect(s.tiles[1].top == 1)
    #expect(Set(s.tiles[1].stack) == [1, 2, 4])

    // Unknown windows are ignored; order of the others is kept.
    var t = screen([1, 2, 3])
    t.arrange([99, 3], capacity: 4)
    #expect(t.tiles.map(\.top) == [3, 1, 2])
}

@Test func constrainMovesSplitsForMinimumSizes() {
    let rect = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let tree = Layout.tree(kind: .grid, count: 2, mainRatio: nil, shape: .normal)
    let w = Layout.constrain(tree, in: rect, gap: 0, weights: [:], mins: [1: CGSize(width: 700, height: 100)])
    let r = Layout.rects(tree, in: rect, gap: 0, weights: w!).leaves
    #expect(r[1]?.width == 700)
    #expect(r[0]?.width == 300)

    // Nested: the right column's minimum reaches the root split.
    let three = Layout.tree(kind: .grid, count: 3, mainRatio: nil, shape: .normal)
    let w3 = Layout.constrain(three, in: rect, gap: 0, weights: [:], mins: [2: CGSize(width: 600, height: 400)])
    let r3 = Layout.rects(three, in: rect, gap: 0, weights: w3!).leaves
    #expect(r3[2]!.width >= 600)
    #expect(r3[2]!.height >= 400)

    // Too big to fit at all.
    #expect(Layout.constrain(tree, in: rect, gap: 0, weights: [:],
                             mins: [0: CGSize(width: 600, height: 0), 1: CGSize(width: 600, height: 0)]) == nil)
    #expect(Layout.constrain(tree, in: rect, gap: 0, weights: [:], mins: [0: CGSize(width: 0, height: 700)]) == nil)
}

@Test func workspaceJSONRoundTrip() throws {
    let json = """
    {"name":"coding","screens":[{"layout":"side","apps":[{"app":"Cursor","open":"~/code/site"},{"app":"Safari","open":"http://localhost:3000"},{"app":"Ghostty"}]}]}
    """
    let ws = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
    #expect(ws.screens[0].layout == .side)
    #expect(ws.screens[0].screen == nil)
    #expect(ws.screens[0].apps[1].open == "http://localhost:3000")
    let again = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(ws))
    #expect(again == ws)
}
