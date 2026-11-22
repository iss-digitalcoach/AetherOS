import AppKit

// Usage: swift make-icon.swift out.png   (renders a 1024×1024 app icon)
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

// macOS icon grid: artwork sits inside an ~824pt squircle.
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(white: 0.16, alpha: 1), NSColor(white: 0.02, alpha: 1)])!.draw(in: squircle, angle: -70)

// Soft top highlight (glass feel)
NSGraphicsContext.saveGraphicsState()
squircle.addClip()
NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)])!
    .draw(in: NSRect(x: 100, y: 520, width: 824, height: 404), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Four-point sparkle
func sparkle(center c: NSPoint, r: CGFloat, waist: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: c.x, y: c.y + r))
    p.curve(to: NSPoint(x: c.x + r, y: c.y), controlPoint1: NSPoint(x: c.x + waist, y: c.y + waist), controlPoint2: NSPoint(x: c.x + waist, y: c.y + waist))
    p.curve(to: NSPoint(x: c.x, y: c.y - r), controlPoint1: NSPoint(x: c.x + waist, y: c.y - waist), controlPoint2: NSPoint(x: c.x + waist, y: c.y - waist))
    p.curve(to: NSPoint(x: c.x - r, y: c.y), controlPoint1: NSPoint(x: c.x - waist, y: c.y - waist), controlPoint2: NSPoint(x: c.x - waist, y: c.y - waist))
    p.curve(to: NSPoint(x: c.x, y: c.y + r), controlPoint1: NSPoint(x: c.x - waist, y: c.y + waist), controlPoint2: NSPoint(x: c.x - waist, y: c.y + waist))
    p.close()
    return p
}
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 1, alpha: 0.5); shadow.shadowBlurRadius = 40; shadow.shadowOffset = .zero
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor.white.setFill()
sparkle(center: NSPoint(x: 512, y: 512), r: 270, waist: 46).fill()
NSGraphicsContext.restoreGraphicsState()
NSColor.white.setFill()
sparkle(center: NSPoint(x: 700, y: 700), r: 84, waist: 14).fill()

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
