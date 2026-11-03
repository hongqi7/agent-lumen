// Draws the Agent Lumen app icon: a dark tile holding a little screen whose edge glows
// blue → green → orange, the three states the app shows. Writes an .iconset for iconutil.
//   swift scripts/make-icon.swift <output.iconset>
import AppKit
import CoreImage

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

let blue   = NSColor(srgbRed: 0.24, green: 0.52, blue: 1.00, alpha: 1)
let green  = NSColor(srgbRed: 0.20, green: 0.80, blue: 0.36, alpha: 1)
let orange = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // tile: macOS icon grid leaves ~100 pt of margin around an 824 pt rounded square
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(tilePath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [NSColor(srgbRed: 0.10, green: 0.11, blue: 0.17, alpha: 1).cgColor,
                                 NSColor(srgbRed: 0.03, green: 0.04, blue: 0.07, alpha: 1).cgColor] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // the screen
    let screen = CGRect(x: 232, y: 300, width: 560, height: 410)
    let screenPath = CGPath(roundedRect: screen, cornerWidth: 46, cornerHeight: 46, transform: nil)

    // the screen edge as a blue → green → orange stroke on a transparent 1024 canvas
    let colors = [blue, green, orange]
    func edgeImage(width: CGFloat) -> CGImage {
        let c = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.addPath(screenPath)
        c.setLineWidth(width)
        c.replacePathWithStrokedPath()
        c.clip()
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: colors.map(\.cgColor) as CFArray, locations: [0, 0.5, 1])!
        c.drawLinearGradient(grad, start: CGPoint(x: screen.minX, y: screen.maxY),
                             end: CGPoint(x: screen.maxX, y: screen.minY), options: [])
        return c.makeImage()!
    }
    func blurred(_ image: CGImage, radius: Double) -> CGImage {
        let ci = CIImage(cgImage: image).clampedToExtent()
            .applyingGaussianBlur(sigma: radius)
            .cropped(to: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        return CIContext().createCGImage(ci, from: ci.extent)!
    }
    let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)

    // screen face, then a wide soft glow spilling both ways across the edge, then the crisp edge
    ctx.addPath(screenPath)
    ctx.setFillColor(NSColor(srgbRed: 0.05, green: 0.06, blue: 0.10, alpha: 1).cgColor)
    ctx.fillPath()
    let edge = edgeImage(width: 26)
    ctx.setAlpha(0.9)
    ctx.draw(blurred(edge, radius: 46), in: full)
    ctx.setAlpha(0.85)
    ctx.draw(blurred(edge, radius: 16), in: full)
    ctx.setAlpha(1)
    ctx.draw(edgeImage(width: 10), in: full)

    // stand
    ctx.setFillColor(NSColor(white: 0.55, alpha: 0.9).cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 470, y: 222, width: 84, height: 70), cornerWidth: 10, cornerHeight: 10, transform: nil))
    ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 392, y: 204, width: 240, height: 26), cornerWidth: 13, cornerHeight: 13, transform: nil))
    ctx.fillPath()

    // status dot in the corner of the screen, like the menu bar light
    let dot = CGRect(x: 704, y: 616, width: 52, height: 52)
    ctx.setFillColor(green.withAlphaComponent(0.35).cgColor)
    ctx.fillEllipse(in: dot.insetBy(dx: -16, dy: -16))
    ctx.setFillColor(green.cgColor)
    ctx.fillEllipse(in: dot)
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let data = draw(px).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
print("wrote \(out)")
