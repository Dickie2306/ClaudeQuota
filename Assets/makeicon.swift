// Generates icon_1024.png — the ClaudeQuota app icon (ring gauge on a dark
// rounded rect, Claude-orange arc). Run via Assets/makeicon.sh, which also
// packages it into AppIcon.icns.
import AppKit

let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Rounded-rect background with the standard macOS icon margin (~9%)
let bgRect = NSRect(x: 92, y: 92, width: 840, height: 840)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: 188, yRadius: 188)
NSColor(calibratedRed: 0.125, green: 0.114, blue: 0.106, alpha: 1).setFill() // warm near-black
bg.fill()

// Gauge ring
let center = NSPoint(x: 512, y: 512)
let radius: CGFloat = 255
let ringWidth: CGFloat = 96

let track = NSBezierPath()
track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
track.lineWidth = ringWidth
NSColor(calibratedWhite: 1, alpha: 0.14).setStroke()
track.stroke()

// Progress arc at ~68%, clockwise from 12 o'clock, Claude-orange
let arc = NSBezierPath()
arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
              endAngle: 90 - 360 * 0.68, clockwise: true)
arc.lineWidth = ringWidth
arc.lineCapStyle = .round
NSColor(calibratedRed: 0.851, green: 0.467, blue: 0.341, alpha: 1).setStroke()
arc.stroke()

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png")
try! png.write(to: out)
print("wrote \(out.path)")
