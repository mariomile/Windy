import AppKit
import WindyCore

/// AX coordinates put the origin at the top-left of the primary screen with y pointing down;
/// Cocoa puts it at the bottom-left with y pointing up. The conversion is its own inverse.
func flipped(_ r: CGRect) -> CGRect {
    let height = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
}

func flippedPoint(_ p: CGPoint) -> CGPoint {
    CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Stable across reboots and reconnects, unlike the display ID.
    var uuid: String {
        guard let cf = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return "\(displayID)" }
        return CFUUIDCreateString(nil, cf) as String
    }

    var axFrame: CGRect { flipped(frame) }
    var axVisibleFrame: CGRect { flipped(visibleFrame) }
    var shape: ScreenShape { ScreenShape(size: frame.size) }

    static func with(uuid: String) -> NSScreen? { screens.first { $0.uuid == uuid } }

    /// The screen holding an AX point, or the nearest one.
    static func containing(axPoint p: CGPoint) -> NSScreen? {
        if let hit = screens.first(where: { $0.axFrame.contains(p) }) { return hit }
        return screens.min { a, b in
            hypot(a.axFrame.midX - p.x, a.axFrame.midY - p.y) < hypot(b.axFrame.midX - p.x, b.axFrame.midY - p.y)
        }
    }

    static var underPointer: NSScreen? { containing(axPoint: flippedPoint(NSEvent.mouseLocation)) }

    /// The next screen in a direction, following the arrangement in System Settings › Displays.
    func neighbor(_ direction: Direction) -> NSScreen? {
        let candidates = Dictionary(uniqueKeysWithValues: NSScreen.screens.enumerated().map { ($0.offset, $0.element.axFrame) })
        guard let i = Layout.neighbor(of: axFrame, in: candidates, direction: direction) else { return nil }
        return NSScreen.screens[i]
    }
}
