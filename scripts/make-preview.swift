// Renders docs/preview.png: a mock desktop showing the three glow colours side by side.
//   swift scripts/make-preview.swift docs/preview.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "preview.png"
let colors: [(NSColor, String)] = [
    (NSColor(srgbRed: 0.24, green: 0.52, blue: 1.00, alpha: 1), "Needs you · 等你批准"),
    (NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1), "Working · 任务中"),
    (NSColor(srgbRed: 0.20, green: 0.80, blue: 0.36, alpha: 1), "Done · 完成任务"),
]
let W = 1800, H = 520
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.setFillColor(NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1).cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

for (i, (color, title)) in colors.enumerated() {
    let screen = CGRect(x: 60 + i * 580, y: 90, width: 520, height: 340)
    let path = CGPath(roundedRect: screen, cornerWidth: 18, cornerHeight: 18, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    // wallpaper
    let wall = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(srgbRed: 0.20, green: 0.22, blue: 0.30, alpha: 1).cgColor,
                                   NSColor(srgbRed: 0.10, green: 0.11, blue: 0.16, alpha: 1).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(wall, start: CGPoint(x: screen.minX, y: screen.maxY), end: CGPoint(x: screen.maxX, y: screen.minY), options: [])
    // a window
    ctx.setFillColor(NSColor(white: 0.97, alpha: 0.95).cgColor)
    ctx.addPath(CGPath(roundedRect: screen.insetBy(dx: 70, dy: 60).offsetBy(dx: 0, dy: -8), cornerWidth: 10, cornerHeight: 10, transform: nil))
    ctx.fillPath()
    // edge glow: same recipe as the app, strongest at the edge and fading inward
    let t: CGFloat = 46
    let edgeGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [color.withAlphaComponent(0.95).cgColor, color.withAlphaComponent(0.4).cgColor,
                                       color.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 0.3, 1])!
    for (a, b) in [(CGPoint(x: screen.midX, y: screen.minY), CGPoint(x: screen.midX, y: screen.minY + t)),
                   (CGPoint(x: screen.midX, y: screen.maxY), CGPoint(x: screen.midX, y: screen.maxY - t)),
                   (CGPoint(x: screen.minX, y: screen.midY), CGPoint(x: screen.minX + t, y: screen.midY)),
                   (CGPoint(x: screen.maxX, y: screen.midY), CGPoint(x: screen.maxX - t, y: screen.midY))] {
        ctx.drawLinearGradient(edgeGrad, start: a, end: b, options: [])
    }
    // menu bar with the status dot
    ctx.setFillColor(NSColor(white: 1, alpha: 0.18).cgColor)
    ctx.fill(CGRect(x: screen.minX, y: screen.maxY - 22, width: screen.width, height: 22))
    ctx.setFillColor(color.withAlphaComponent(0.35).cgColor)
    ctx.fillEllipse(in: CGRect(x: screen.maxX - 150, y: screen.maxY - 19, width: 16, height: 16))
    ctx.setFillColor(color.cgColor)
    ctx.fillEllipse(in: CGRect(x: screen.maxX - 146, y: screen.maxY - 15, width: 8, height: 8))
    ctx.restoreGState()

    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26, weight: .semibold),
                                                .foregroundColor: NSColor(white: 0.2, alpha: 1)]
    let s = NSAttributedString(string: title, attributes: attrs)
    s.draw(at: NSPoint(x: screen.midX - s.size().width / 2, y: 36))
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
