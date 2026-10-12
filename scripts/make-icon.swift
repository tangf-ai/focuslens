import AppKit
import Foundation
let output = CommandLine.arguments[1]
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
NSColor(red: 0.95, green: 0.95, blue: 0.93, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200).fill()
let ring = NSBezierPath(ovalIn: NSRect(x: 260, y: 260, width: 504, height: 504))
ring.lineWidth = 9
NSColor(red: 0.16, green: 0.18, blue: 0.17, alpha: 0.18).setStroke()
ring.stroke()
let arc = NSBezierPath()
arc.appendArc(withCenter: NSPoint(x: 512, y: 512), radius: 252, startAngle: 90, endAngle: -125, clockwise: true)
arc.lineWidth = 18
arc.lineCapStyle = .round
NSColor(red: 0.76, green: 0.31, blue: 0.19, alpha: 1).setStroke()
arc.stroke()
let hand = NSBezierPath()
hand.move(to: NSPoint(x: 512, y: 660)); hand.line(to: NSPoint(x: 512, y: 512)); hand.line(to: NSPoint(x: 615, y: 465))
hand.lineWidth = 20; hand.lineCapStyle = .round; hand.lineJoinStyle = .round
NSColor(red: 0.16, green: 0.18, blue: 0.17, alpha: 1).setStroke(); hand.stroke()
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
