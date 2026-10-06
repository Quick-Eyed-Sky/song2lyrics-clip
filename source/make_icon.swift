// Draws the app icon (a night-blue tile, a sung waveform, three lyric lines with their time marks)
// and writes AppIcon.iconset next to this file.   Run: ./make_icon.sh
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let here = URL(fileURLWithPath: CommandLine.arguments[1])
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func icon(size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(size) / 1024
    let rect = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)      // macOS icon grid
    let shape = CGPath(roundedRect: rect, cornerWidth: 185 * k, cornerHeight: 185 * k, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let colors = [CGColor(red: 0.10, green: 0.11, blue: 0.24, alpha: 1), CGColor(red: 0.29, green: 0.16, blue: 0.42, alpha: 1),
                  CGColor(red: 0.62, green: 0.25, blue: 0.47, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // the voice: a symmetric waveform in the upper half
    let bars = 23
    let barW = 16 * k, gap = 12.5 * k
    let total = CGFloat(bars) * barW + CGFloat(bars - 1) * gap
    let x0 = rect.midX - total / 2, mid = rect.minY + 600 * k
    for i in 0..<bars {
        let p = Double(i) / Double(bars - 1)
        let envelope = sin(p * .pi)
        let wiggle = 0.55 + 0.45 * abs(sin(Double(i) * 1.7) * cos(Double(i) * 0.6))
        let h = CGFloat(30 + 230 * envelope * wiggle) * k
        let bar = CGRect(x: x0 + CGFloat(i) * (barW + gap), y: mid - h / 2, width: barW, height: h)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
    }
    ctx.setFillColor(CGColor(red: 1, green: 0.80, blue: 0.55, alpha: 1))
    ctx.fillPath()

    // the words: three lines, each with its time mark (a small pill) in front
    let rows: [(CGFloat, CGFloat)] = [(330, 470), (250, 400), (170, 440)]       // (y, length of the line)
    for (n, (y, length)) in rows.enumerated() {
        let left = rect.minX + 130 * k
        let mark = CGRect(x: left, y: rect.minY + y * k, width: 95 * k, height: 34 * k)
        ctx.addPath(CGPath(roundedRect: mark, cornerWidth: 17 * k, cornerHeight: 17 * k, transform: nil))
        ctx.setFillColor(CGColor(red: 1, green: 0.80, blue: 0.55, alpha: n == 0 ? 1 : 0.55))
        ctx.fillPath()
        let words = CGRect(x: left + 125 * k, y: rect.minY + y * k, width: length * k, height: 34 * k)
        ctx.addPath(CGPath(roundedRect: words, cornerWidth: 17 * k, cornerHeight: 17 * k, transform: nil))
        ctx.setFillColor(CGColor(gray: 1, alpha: n == 0 ? 0.95 : 0.45))
        ctx.fillPath()
    }
    ctx.restoreGState()
    return ctx.makeImage()!
}

let iconset = here.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let url = iconset.appendingPathComponent("\(name).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, icon(size: px), nil)
    CGImageDestinationFinalize(dest)
}
print("iconset written")
