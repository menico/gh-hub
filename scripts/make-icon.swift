// Renders Bundle/hub.icns: a violet-to-blue squircle with a pull-request glyph.
//   swift scripts/make-icon.swift
import AppKit

func render(_ size: CGFloat) -> Data {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let inset = rect.insetBy(dx: size * 0.09, dy: size * 0.09)
        let shape = NSBezierPath(roundedRect: inset, xRadius: size * 0.2, yRadius: size * 0.2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = size * 0.03
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
        shadow.set()
        NSColor.black.setFill(); shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: [
            NSColor(red: 0.62, green: 0.40, blue: 1.0, alpha: 1),
            NSColor(red: 0.22, green: 0.45, blue: 0.98, alpha: 1),
            NSColor(red: 0.10, green: 0.18, blue: 0.45, alpha: 1),
        ])!.draw(in: shape, angle: -60)
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
            .draw(in: NSBezierPath(roundedRect: inset, xRadius: size * 0.2, yRadius: size * 0.2), angle: -90)
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let glyph = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let g = glyph.size
            glyph.draw(in: NSRect(x: (size - g.width) / 2, y: (size - g.height) / 2, width: g.width, height: g.height))
        }
        return true
    }
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: "build/hub.iconset")
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(CGFloat(base)).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(CGFloat(base * 2)).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
