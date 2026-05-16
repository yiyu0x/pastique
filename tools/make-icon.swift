#!/usr/bin/env swift
// Generates Resources/AppIcon.iconset and compiles to AppIcon.icns via iconutil.
// Re-run any time the icon should be rebranded.
//
// Design: teal-to-blue diagonal gradient squircle background, white SF Symbol
// clipboard glyph centered, ~22.5% corner radius (Apple's macOS app icon spec).

import AppKit
import Foundation

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func renderIcon(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let f = CGFloat(pixels)
    let rect = NSRect(x: 0, y: 0, width: f, height: f)

    // Squircle clip
    let cornerRadius = f * 0.225
    let squircle = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    squircle.addClip()

    // Diagonal teal → deep blue gradient
    let gradient = NSGradient(colors: [
        NSColor(red: 0.16, green: 0.78, blue: 0.79, alpha: 1.0),    // top-left teal
        NSColor(red: 0.18, green: 0.45, blue: 0.92, alpha: 1.0),    // bottom-right blue
    ])!
    gradient.draw(in: rect, angle: -45)

    // Subtle inner highlight at the top
    let highlightHeight = f * 0.5
    let highlightRect = NSRect(x: 0, y: f - highlightHeight, width: f, height: highlightHeight)
    let highlightGradient = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.18),
        NSColor.white.withAlphaComponent(0.0),
    ])!
    highlightGradient.draw(in: highlightRect, angle: -90)

    // Foreground glyph — clipboard with a list on it, rendered in
    // hierarchical white so internal layers (the list bars) keep their
    // depth instead of flattening into a single white silhouette.
    let glyphPointSize = f * 0.55
    let sizeConfig = NSImage.SymbolConfiguration(pointSize: glyphPointSize, weight: .semibold)
    let colorConfig = NSImage.SymbolConfiguration(hierarchicalColor: .white)
    let symbolConfig = sizeConfig.applying(colorConfig)

    if let baseSymbol = NSImage(systemSymbolName: "list.clipboard.fill",
                                accessibilityDescription: nil),
       let configured = baseSymbol.withSymbolConfiguration(symbolConfig) {
        let symbolSize = configured.size
        let scale = min(f * 0.55 / symbolSize.width, f * 0.55 / symbolSize.height)
        let drawSize = NSSize(width: symbolSize.width * scale,
                              height: symbolSize.height * scale)
        let origin = NSPoint(x: (f - drawSize.width) / 2,
                             y: (f - drawSize.height) / 2)
        let drawRect = NSRect(origin: origin, size: drawSize)

        // Subtle shadow for depth against the gradient
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowOffset = NSSize(width: 0, height: -f * 0.01)
        shadow.shadowBlurRadius = f * 0.025
        shadow.set()

        configured.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])!
}

let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
let repoRoot = scriptDir.deletingLastPathComponent()
let iconsetURL = repoRoot.appendingPathComponent("Resources/AppIcon.iconset")

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL,
                                         withIntermediateDirectories: true)

for size in sizes {
    let data = renderIcon(pixels: size.px)
    let url = iconsetURL.appendingPathComponent(size.name)
    try data.write(to: url)
    print("  ✓ \(size.name)  \(size.px)×\(size.px)")
}

print("==> compiling AppIcon.icns")
let icnsURL = repoRoot.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", "-o", icnsURL.path, iconsetURL.path]
try task.run()
task.waitUntilExit()

if task.terminationStatus == 0 {
    print("==> wrote \(icnsURL.path)")
} else {
    print("ERROR: iconutil exited with \(task.terminationStatus)")
    exit(1)
}
