#!/usr/bin/env swift
// Generates build/AppIcon.icns — a rounded gradient tile with a white "waveform".
// Run: swift scripts/make-icon.swift
import AppKit
import Foundation

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.225, yRadius: s * 0.225)
    bg.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.29, green: 0.36, blue: 0.96, alpha: 1),
                        NSColor(srgbRed: 0.56, green: 0.24, blue: 0.86, alpha: 1)])!
        .draw(in: rect, angle: -90)

    NSColor.white.setFill()
    let heights: [CGFloat] = [0.28, 0.52, 0.82, 0.42, 0.66, 0.34]
    let n = heights.count
    let barW = s * 0.082
    let gap = (s - CGFloat(n) * barW) / CGFloat(n + 1)
    for (i, h) in heights.enumerated() {
        let bh = s * h
        let x = gap + CGFloat(i) * (barW + gap)
        let y = (s - bh) / 2
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barW, height: bh),
                     xRadius: barW / 2, yRadius: barW / 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.first ?? ".")
    .deletingLastPathComponent().deletingLastPathComponent()
let buildDir = root.appendingPathComponent("build")
let iconset = buildDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let specs: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (sz, name) in specs {
    try render(sz).write(to: iconset.appendingPathComponent(name))
}
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path, "-o", buildDir.appendingPathComponent("AppIcon.icns").path]
try proc.run(); proc.waitUntilExit()
print(proc.terminationStatus == 0 ? "wrote build/AppIcon.icns" : "iconutil failed")
