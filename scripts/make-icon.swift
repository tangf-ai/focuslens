import AppKit
import Foundation
let output = CommandLine.arguments[1]
let size = 1024
func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
color(0xf7f9fc).setFill()
NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200).fill()
let ring = NSBezierPath(ovalIn: NSRect(x: 260, y: 260, width: 504, height: 504))
ring.lineWidth = 9
color(0x2d61d3, alpha: 0.16).setStroke()
ring.stroke()
let arc = NSBezierPath()
arc.appendArc(withCenter: NSPoint(x: 512, y: 512), radius: 252, startAngle: 90, endAngle: -125, clockwise: true)
arc.lineWidth = 18
arc.lineCapStyle = .round
color(0x2d61d3).setStroke()
arc.stroke()
let hand = NSBezierPath()
hand.move(to: NSPoint(x: 512, y: 660)); hand.line(to: NSPoint(x: 512, y: 512)); hand.line(to: NSPoint(x: 615, y: 465))
hand.lineWidth = 20; hand.lineCapStyle = .round; hand.lineJoinStyle = .round
color(0x25334a).setStroke(); hand.stroke()
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
