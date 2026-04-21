// scripts/generate-icon.swift
//
// v0.7.0 — generate the Lumina app icon programmatically and emit an
// AppIcon.icns ready to drop into Resources/.
//
// Run: swift scripts/generate-icon.swift
// Output: scripts/AppIcon.iconset/, scripts/AppIcon.icns
//
// Brand: a phosphor-amber rectangle layered with an offset cream rectangle
// (matches the brand-mark in the website) on a deep-graphite squircle base.
// Single-stroke geometry, no gradients in the marks themselves — the
// background gradient does the lift.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16",      16),
    ("icon_16x16@2x",   32),
    ("icon_32x32",      32),
    ("icon_32x32@2x",   64),
    ("icon_128x128",    128),
    ("icon_128x128@2x", 256),
    ("icon_256x256",    256),
    ("icon_256x256@2x", 512),
    ("icon_512x512",    512),
    ("icon_512x512@2x", 1024),
]

func makeIcon(size: Int) -> Data {
    let s = CGFloat(size)
    let scale: CGFloat = 1
    let bytesPerRow = size * 4
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                              space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("CGContext")
    }
    let rect = CGRect(x: 0, y: 0, width: s, height: s)

    // ── Background: macOS rounded squircle with deep-graphite gradient ──
    let cornerRadius: CGFloat = s * 0.225  // matches macOS Big Sur+ icon mask
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).cgPath
    ctx.addPath(path)
    ctx.clip()

    let bgGradient = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 0.10, green: 0.085, blue: 0.07, alpha: 1.0),  // top — slightly warm
            CGColor(red: 0.04, green: 0.035, blue: 0.03, alpha: 1.0),  // bottom — near black
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(bgGradient, start: CGPoint(x: 0, y: s),
                           end: CGPoint(x: 0, y: 0), options: [])

    // ── Subtle inner highlight (top edge sheen) ──
    ctx.saveGState()
    ctx.setBlendMode(.screen)
    let highlightGrad = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 1.0, green: 0.95, blue: 0.85, alpha: 0.10),
            CGColor(red: 1.0, green: 0.95, blue: 0.85, alpha: 0.0),
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(highlightGrad,
                           start: CGPoint(x: 0, y: s),
                           end: CGPoint(x: 0, y: s * 0.55),
                           options: [])
    ctx.restoreGState()

    // ── Brand mark: two offset squares (amber + cream) ──
    // Geometry mirrors the website's brand-mark CSS exactly.
    let markSize = s * 0.42
    let markStroke = max(1.0, s * 0.018)
    let amberOrigin = CGPoint(x: s * 0.27, y: s * 0.36)
    let creamOrigin = CGPoint(x: amberOrigin.x + markSize * 0.20,
                              y: amberOrigin.y + markSize * 0.20)

    // Cream square (back layer)
    ctx.setStrokeColor(CGColor(red: 0.91, green: 0.89, blue: 0.85, alpha: 0.55))
    ctx.setLineWidth(markStroke)
    ctx.stroke(CGRect(origin: creamOrigin,
                      size: CGSize(width: markSize, height: markSize)))

    // Amber square (front layer) with a soft glow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012),
                  blur: s * 0.04,
                  color: CGColor(red: 1.0, green: 0.7, blue: 0.28, alpha: 0.55))
    ctx.setStrokeColor(CGColor(red: 1.0, green: 0.7, blue: 0.28, alpha: 1.0))
    ctx.setLineWidth(markStroke)
    ctx.stroke(CGRect(origin: amberOrigin,
                      size: CGSize(width: markSize, height: markSize)))
    ctx.restoreGState()

    // ── Tiny phosphor dot in upper-right (running indicator vibe) ──
    let dotR = s * 0.018
    let dotCx = s * 0.78, dotCy = s * 0.76
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.04,
                  color: CGColor(red: 1.0, green: 0.7, blue: 0.28, alpha: 0.7))
    ctx.setFillColor(CGColor(red: 1.0, green: 0.75, blue: 0.32, alpha: 1.0))
    ctx.fillEllipse(in: CGRect(x: dotCx - dotR, y: dotCy - dotR,
                               width: dotR * 2, height: dotR * 2))
    ctx.restoreGState()

    guard let cg = ctx.makeImage() else { fatalError("makeImage") }
    let nsImage = NSImage(cgImage: cg, size: NSSize(width: s, height: s))
    guard let tiff = nsImage.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("png")
    }
    return png
}

// NSBezierPath.cgPath polyfill (older SDKs)
extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var pts = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &pts) {
            case .moveTo: path.move(to: pts[0])
            case .lineTo: path.addLine(to: pts[0])
            case .curveTo: path.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}

// MAIN
let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconsetURL = here.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

print("→ Rendering icon at \(sizes.count) sizes")
for (name, px) in sizes {
    let data = makeIcon(size: px)
    let url = iconsetURL.appendingPathComponent("\(name).png")
    try data.write(to: url)
    print("  ✓ \(name).png (\(px)×\(px))")
}

print("→ Calling iconutil to produce AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", "-o", here.appendingPathComponent("AppIcon.icns").path,
                  iconsetURL.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    print("error: iconutil failed with code \(task.terminationStatus)")
    exit(1)
}
print("✓ Wrote \(here.path)/AppIcon.icns")
