// Generates the app icon placeholder: a dark rounded square with a white
// shield and a green status dot. Run via `scripts/make-icon.sh`.
// Usage: swift scripts/generate-icon.swift <output.png>

import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: generate-icon.swift <output.png>\n".data(using: .utf8)!)
    exit(1)
}
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

let size = 1024.0

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else {
    FileHandle.standardError.write("failed to create bitmap\n".data(using: .utf8)!)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write("failed to create graphics context\n".data(using: .utf8)!)
    exit(1)
}
NSGraphicsContext.current = ctx

// Background: dark graphite-blue rounded square with a vertical gradient.
let cornerRadius = size * 0.2275
let background = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                              xRadius: cornerRadius, yRadius: cornerRadius)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.27, alpha: 1),
    NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.13, alpha: 1),
])!
gradient.draw(in: background, angle: -90)

// Shield: white badge centered slightly above the middle.
let cx = size / 2
let shieldWidth = size * 0.46
let hw = shieldWidth / 2
let top = size * 0.70
let bottom = size * 0.26
let shieldHeight = top - bottom

let shield = NSBezierPath()
shield.move(to: CGPoint(x: cx - hw, y: top))
shield.line(to: CGPoint(x: cx + hw, y: top))
shield.curve(to: CGPoint(x: cx, y: bottom),
             controlPoint1: CGPoint(x: cx + hw, y: top - shieldHeight * 0.55),
             controlPoint2: CGPoint(x: cx + hw * 0.72, y: bottom + shieldHeight * 0.18))
shield.curve(to: CGPoint(x: cx - hw, y: top),
             controlPoint1: CGPoint(x: cx - hw * 0.72, y: bottom + shieldHeight * 0.18),
             controlPoint2: CGPoint(x: cx - hw, y: top - shieldHeight * 0.55))
shield.close()
NSColor.white.setFill()
shield.fill()

// Green status dot — "tunnel is up", same semantics as the fresh-handshake
// dot in the status card.
let dotCenter = CGPoint(x: cx, y: size * 0.475)
let dotRadius = size * 0.125
let dot = NSBezierPath(ovalIn: NSRect(x: dotCenter.x - dotRadius, y: dotCenter.y - dotRadius,
                                      width: dotRadius * 2, height: dotRadius * 2))
NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.35, alpha: 1).setFill()
dot.fill()

NSGraphicsContext.current = nil
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to encode png\n".data(using: .utf8)!)
    exit(1)
}
do {
    try png.write(to: outputURL)
} catch {
    FileHandle.standardError.write("failed to write \(outputURL.path): \(error)\n".data(using: .utf8)!)
    exit(1)
}
