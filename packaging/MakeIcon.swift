// Generates MirrorDeck's app icon as an .iconset (run by scripts/package.sh).
// Dependency-free: renders with CoreGraphics, no design assets to ship.
//
//   swift packaging/MakeIcon.swift <output.iconset>

import AppKit

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon.iconset"
try? FileManager.default.createDirectory(
    atPath: outputDir, withIntermediateDirectories: true)

/// Draws the icon at an arbitrary size: a phone silhouette floating on a
/// deep gradient, with a soft "cast screen" glow behind it.
func drawIcon(size: CGFloat, into context: CGContext) {
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    context.saveGState()

    // Rounded-rect background clip (macOS icon "squircle" proportions).
    let corner = size * 0.2237
    let path = CGPath(roundedRect: rect, cornerWidth: corner,
                      cornerHeight: corner, transform: nil)
    context.addPath(path)
    context.clip()

    // Background gradient: near-black to deep indigo.
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        CGColor(colorSpace: colorSpace, components: [0.10, 0.11, 0.16, 1.0])!,
        CGColor(colorSpace: colorSpace, components: [0.04, 0.04, 0.07, 1.0])!,
    ]
    if let gradient = CGGradient(colorsSpace: colorSpace,
                                 colors: bgColors as CFArray,
                                 locations: [0.0, 1.0]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: size),
            end: CGPoint(x: size, y: 0),
            options: [])
    }

    // Glow behind the phone, suggesting a screen being cast.
    let glowColors = [
        CGColor(colorSpace: colorSpace, components: [0.35, 0.55, 1.0, 0.55])!,
        CGColor(colorSpace: colorSpace, components: [0.35, 0.55, 1.0, 0.0])!,
    ]
    if let glow = CGGradient(colorsSpace: colorSpace,
                             colors: glowColors as CFArray,
                             locations: [0.0, 1.0]) {
        context.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: size / 2, y: size * 0.52), startRadius: 0,
            endCenter: CGPoint(x: size / 2, y: size * 0.52), endRadius: size * 0.42,
            options: [])
    }

    // Phone body.
    let phoneWidth = size * 0.34
    let phoneHeight = size * 0.60
    let phoneRect = CGRect(x: (size - phoneWidth) / 2,
                           y: (size - phoneHeight) / 2,
                           width: phoneWidth, height: phoneHeight)
    let phoneCorner = phoneWidth * 0.24

    context.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                      blur: size * 0.05,
                      color: CGColor(colorSpace: colorSpace,
                                     components: [0, 0, 0, 0.55])!)
    context.addPath(CGPath(roundedRect: phoneRect, cornerWidth: phoneCorner,
                           cornerHeight: phoneCorner, transform: nil))
    context.setFillColor(CGColor(colorSpace: colorSpace,
                                 components: [0.96, 0.97, 1.0, 1.0])!)
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0, color: nil)

    // Screen inset, tinted like a live mirror.
    let inset = phoneWidth * 0.075
    let screenRect = phoneRect.insetBy(dx: inset, dy: inset)
    context.addPath(CGPath(roundedRect: screenRect,
                           cornerWidth: phoneCorner - inset * 0.6,
                           cornerHeight: phoneCorner - inset * 0.6,
                           transform: nil))
    context.clip()
    let screenColors = [
        CGColor(colorSpace: colorSpace, components: [0.29, 0.51, 0.99, 1.0])!,
        CGColor(colorSpace: colorSpace, components: [0.14, 0.20, 0.45, 1.0])!,
    ]
    if let screenGradient = CGGradient(colorsSpace: colorSpace,
                                       colors: screenColors as CFArray,
                                       locations: [0.0, 1.0]) {
        context.drawLinearGradient(
            screenGradient,
            start: CGPoint(x: screenRect.minX, y: screenRect.maxY),
            end: CGPoint(x: screenRect.maxX, y: screenRect.minY),
            options: [])
    }
    context.restoreGState()
}

func writePNG(size: Int, to path: String) {
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    drawIcon(size: CGFloat(size), into: context)
    guard let image = context.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
}

// The sizes `iconutil` expects in an .iconset.
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                        (256, 1), (256, 2), (512, 1), (512, 2)] {
    let suffix = scale == 2 ? "@2x" : ""
    let name = "icon_\(points)x\(points)\(suffix).png"
    writePNG(size: points * scale, to: "\(outputDir)/\(name)")
}
print("wrote iconset to \(outputDir)")
