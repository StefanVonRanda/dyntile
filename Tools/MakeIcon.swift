#!/usr/bin/env swift
import AppKit
import CoreGraphics
import UniformTypeIdentifiers

// Renders dyntile's app icon at every size macOS asks for, then hands the iconset to
// iconutil. The art is the `tall` layout itself: one main tile beside a stack of two.
// Each size is drawn from scratch rather than downscaled, so 16pt stays crisp, and the
// gaps are floored at just over a pixel so the three tiles never merge into one block.

struct Palette {
    static let backdropTop = CGColor(red: 0.325, green: 0.278, blue: 0.898, alpha: 1)    // #5347E5
    static let backdropBottom = CGColor(red: 0.086, green: 0.098, blue: 0.204, alpha: 1)  // #161934
    static let mainTile = CGColor(red: 0.973, green: 0.980, blue: 0.988, alpha: 1.0)
    static let stackTileTop = CGColor(red: 0.973, green: 0.980, blue: 0.988, alpha: 0.62)
    static let stackTileBottom = CGColor(red: 0.973, green: 0.980, blue: 0.988, alpha: 0.42)
}

/// A superellipse — the continuous "squircle" corner macOS uses, rather than the
/// circular arc of a plain rounded rect.
func squircle(in rect: CGRect, exponent: Double = 6.2, samples: Int = 512) -> CGPath {
    let path = CGMutablePath()
    let a = Double(rect.width) / 2, b = Double(rect.height) / 2
    let cx = Double(rect.midX), cy = Double(rect.midY)
    for i in 0...samples {
        let t = Double(i) / Double(samples) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2 / exponent), ct)
        let y = cy + b * copysign(pow(abs(st), 2 / exponent), st)
        let point = CGPoint(x: x, y: y)
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

func drawIcon(size: CGFloat, into ctx: CGContext) {
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // The macOS icon grid: the squircle fills 824 of a 1024pt canvas. Below 32pt that
    // margin costs more legibility than it buys, so the plate grows to fill the tile.
    let insetRatio: CGFloat = size <= 32 ? 0.035 : 100.0 / 1024.0
    let inset = (size * insetRatio).rounded()
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = squircle(in: plate)

    // A soft shadow under the plate, as system icons have.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                  blur: size * 0.03,
                  color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Backdrop gradient, top-left light.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    // Lit from the top-left, the way every system icon is lit.
    if let gradient = CGGradient(colorsSpace: space,
                                 colors: [Palette.backdropTop, Palette.backdropBottom] as CFArray,
                                 locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: plate.minX, y: plate.maxY),
                               end: CGPoint(x: plate.maxX, y: plate.minY),
                               options: [])
    }
    // A cool sheen in that same corner keeps the plate from reading flat.
    let sheenCentre = CGPoint(x: plate.minX + plate.width * 0.12,
                              y: plate.maxY - plate.height * 0.08)
    if let sheen = CGGradient(colorsSpace: space,
                              colors: [CGColor(red: 0.45, green: 0.82, blue: 1.0, alpha: 0.55),
                                       CGColor(red: 0.45, green: 0.82, blue: 1.0, alpha: 0.0)] as CFArray,
                              locations: [0, 1]) {
        ctx.drawRadialGradient(sheen,
                               startCenter: sheenCentre, startRadius: 0,
                               endCenter: sheenCentre, endRadius: plate.width * 0.78,
                               options: [])
    }
    ctx.restoreGState()

    // The layout itself.
    // Inset from the plate, not the canvas, so the small sizes — whose plate is
    // proportionally larger — keep the same composition.
    let margin = (plate.width * 0.092).rounded()
    let work = plate.insetBy(dx: margin, dy: margin)
    let gap = max((plate.width * 0.053).rounded(), 1.5)
    let radius = max(plate.width * 0.053, 1.0)

    let mainWidth = ((work.width - gap) * 0.55).rounded()
    let main = CGRect(x: work.minX, y: work.minY, width: mainWidth, height: work.height)
    let stackX = work.minX + mainWidth + gap
    let stackWidth = work.maxX - stackX
    let stackHeight = ((work.height - gap) / 2).rounded()
    let upper = CGRect(x: stackX, y: work.maxY - stackHeight, width: stackWidth, height: stackHeight)
    let lower = CGRect(x: stackX, y: work.minY, width: stackWidth, height: stackHeight)

    func tile(_ rect: CGRect, _ color: CGColor) {
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: min(radius, rect.width / 2),
                           cornerHeight: min(radius, rect.height / 2), transform: nil))
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    tile(main, Palette.mainTile)
    tile(upper, Palette.stackTileTop)
    tile(lower, Palette.stackTileBottom)
}

func render(size: Int) -> CGImage? {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    drawIcon(size: CGFloat(size), into: ctx)
    return ctx.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "makeicon", code: 1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "makeicon", code: 2) }
}

// MARK: - main

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let iconset = URL(fileURLWithPath: outDir).appendingPathComponent("dyntile.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// (point size, scale) pairs macOS expects in an iconset.
let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                              (256, 1), (256, 2), (512, 1), (512, 2)]
for (points, scale) in variants {
    let pixels = points * scale
    guard let image = render(size: pixels) else {
        FileHandle.standardError.write("failed to render \(pixels)px\n".data(using: .utf8)!)
        exit(1)
    }
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try write(image, to: iconset.appendingPathComponent(name))
}

let icns = URL(fileURLWithPath: outDir).appendingPathComponent("dyntile.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { exit(task.terminationStatus) }
// keep the iconset when DYNTILE_KEEP_ICONSET is set, for inspecting the small sizes
if ProcessInfo.processInfo.environment["DYNTILE_KEEP_ICONSET"] == nil {
    try? FileManager.default.removeItem(at: iconset)
}
print("wrote \(icns.path)")
