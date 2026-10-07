// Renders Resources/QuotaBarIconSource.png. AppKit draws at 2x, so scale the result down:
//   swift scripts/render-icon.swift /tmp/icon.png && sips -z 1024 1024 /tmp/icon.png --out Resources/QuotaBarIconSource.png
// Then build Resources/QuotaBar.icns from it with sips and iconutil.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let context = NSGraphicsContext.current!.cgContext

// White canvas like the previous icon.
NSColor.white.setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()

// Symbol tile.
let tile = NSRect(x: 232, y: 330, width: 560, height: 560)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 150, yRadius: 150)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: NSColor(calibratedRed: 0.22, green: 0.24, blue: 0.94, alpha: 0.28).cgColor)
NSColor.white.setFill()
tilePath.fill()
context.restoreGState()
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.73, green: 0.65, blue: 0.97, alpha: 1),
    NSColor(calibratedRed: 0.43, green: 0.55, blue: 0.96, alpha: 1),
    NSColor(calibratedRed: 0.20, green: 0.21, blue: 0.94, alpha: 1)
], atLocations: [0, 0.5, 1], colorSpace: .deviceRGB)!
gradient.draw(in: tilePath, angle: -90)

// Gauge: a 270° track with a filled share, opening at the bottom.
let center = CGPoint(x: tile.midX, y: tile.midY - 6)
let radius: CGFloat = 170
let lineWidth: CGFloat = 58
func arc(from start: CGFloat, to end: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
    path.lineWidth = lineWidth
    path.lineCapStyle = .round
    return path
}
NSColor.white.withAlphaComponent(0.32).setStroke()
arc(from: 225, to: -45).stroke()
NSColor.white.setStroke()
arc(from: 225, to: 225 - 270 * 0.62).stroke()

// Needle hub.
let hub = NSBezierPath(ovalIn: NSRect(x: center.x - 40, y: center.y - 40, width: 80, height: 80))
NSColor.white.setFill()
hub.fill()

// Name below the symbol.
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let font = NSFont.systemFont(ofSize: 132, weight: .bold)
let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.15, alpha: 1),
    .paragraphStyle: paragraph,
    .kern: -1.5
]
NSString(string: "Quota Bar").draw(in: NSRect(x: 0, y: 92, width: size, height: 170), withAttributes: attributes)

image.unlockFocus()
let rep = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
rep.size = NSSize(width: size, height: size)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
