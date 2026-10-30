// Renders the 1024px app icon to the path given as the first argument.
// Mirrors WindyIcon.app in the app target.
import AppKit

func color(_ hex: String) -> NSColor {
    let v = UInt32(hex.dropFirst(), radix: 16)!
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

let s: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s), pixelsHigh: Int(s), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let rect = CGRect(x: 0, y: 0, width: s, height: s)
let bg = NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.1, dy: s * 0.1), xRadius: s * 0.18, yRadius: s * 0.18)
NSGradient(starting: color("#F6F1E7"), ending: color("#E7DFD0"))!.draw(in: bg, angle: -90)
let inner = rect.insetBy(dx: s * 0.24, dy: s * 0.24)
let g = s * 0.035
let w = (inner.width - g) / 2
let origins = [CGPoint(x: inner.minX, y: inner.minY + w + g), CGPoint(x: inner.minX + w + g, y: inner.minY + w + g),
               CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.minX + w + g, y: inner.minY)]
for (o, c) in zip(origins, ["#1F2328", "#E4572E", "#1F2328", "#1F2328"]) {
    color(c).setFill()
    NSBezierPath(roundedRect: CGRect(origin: o, size: CGSize(width: w, height: w)), xRadius: s * 0.035, yRadius: s * 0.035).fill()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
