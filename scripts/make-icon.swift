#!/usr/bin/env swift
//
// Renders Sigil's app icon: the menu-bar "⌘" glyph in black on a white macOS-style rounded tile,
// then packs every required size into bundle/AppIcon.icns.
//
// Usage:  swift scripts/make-icon.swift            (run from the repo root)
//
// Re-run whenever the design here changes; the generated .icns is committed so normal builds
// don't need this step.

import AppKit

let canvas: CGFloat = 1024
// Apple's macOS icon grid: an 824pt body centred on the 1024pt canvas, ~185pt corner radius,
// leaving room for the drop shadow.
let body: CGFloat = 824
let corner: CGFloat = 185

func renderIcon(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: canvas, height: canvas) // draw in 1024pt space at any pixel size

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let inset = (canvas - body) / 2
    let tile = NSRect(x: inset, y: inset + 10, width: body, height: body) // nudge up for shadow
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: corner, yRadius: corner)

    // Soft drop shadow, as on standard macOS icons.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 24
    shadow.set()
    NSColor.white.setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Black outline around the white tile so it reads on light backgrounds too.
    let edge = NSBezierPath(
        roundedRect: tile.insetBy(dx: 6, dy: 6), xRadius: corner - 6, yRadius: corner - 6
    )
    edge.lineWidth = 12
    NSColor.black.setStroke()
    edge.stroke()

    // The "⌘" glyph, as in the menu bar, centred optically on the tile.
    let font = NSFont.systemFont(ofSize: 620, weight: .regular)
    let glyph = NSAttributedString(string: "⌘", attributes: [
        .font: font,
        .foregroundColor: NSColor.black,
    ])
    let line = CTLineCreateWithAttributedString(glyph)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let origin = CGPoint(
        x: tile.midX - bounds.width / 2 - bounds.minX,
        y: tile.midY - bounds.height / 2 - bounds.minY
    )
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.textPosition = origin
    CTLineDraw(line, ctx)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

for base in [16, 32, 128, 256, 512] {
    try renderIcon(pixels: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try renderIcon(pixels: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
// A full-size preview next to the .icns for quick review.
try renderIcon(pixels: 1024).write(to: root.appendingPathComponent("bundle/AppIcon-preview.png"))

let output = root.appendingPathComponent("bundle/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
