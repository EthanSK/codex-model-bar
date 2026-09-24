// Editable source for the app icon. Run via scripts/build-app.sh, which turns the
// rendered PNGs into Resources/AppIcon.icns with `iconutil`.
//
// Design: a dark rounded square (the Codex window) with a bright strip of three
// pills underneath it (the model bar), the middle pill highlighted as "current".
import AppKit

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: ~10% transparent margin around a rounded-square body.
    let inset = s * 0.1
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.225
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.16, alpha: 1),
                        NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.32, alpha: 1)])!
        .draw(in: bodyPath, angle: 90)

    // "Window": a lighter panel in the upper part with a title-bar line.
    let window = CGRect(x: body.minX + body.width * 0.14, y: body.minY + body.height * 0.40,
                        width: body.width * 0.72, height: body.height * 0.44)
    NSColor(calibratedWhite: 1, alpha: 0.14).setFill()
    NSBezierPath(roundedRect: window, xRadius: s * 0.035, yRadius: s * 0.035).fill()
    NSColor(calibratedWhite: 1, alpha: 0.28).setFill()
    NSBezierPath(roundedRect: CGRect(x: window.minX, y: window.maxY - s * 0.05, width: window.width, height: s * 0.05),
                 xRadius: s * 0.02, yRadius: s * 0.02).fill()

    // "Bar": three pills attached under the window; the middle one is the current model.
    let barY = window.minY - body.height * 0.16
    let pillW = window.width * 0.29, pillH = body.height * 0.11, gap = window.width * 0.065
    let startX = window.midX - (3 * pillW + 2 * gap) / 2
    for i in 0..<3 {
        let rect = CGRect(x: startX + CGFloat(i) * (pillW + gap), y: barY, width: pillW, height: pillH)
        let color = i == 1 ? NSColor(calibratedRed: 0.36, green: 0.62, blue: 1.0, alpha: 1)
                           : NSColor(calibratedWhite: 1, alpha: 0.30)
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: pillH / 2, yRadius: pillH / 2).fill()
    }
    ctx.flush()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// Standard iconset members: 16…512 at 1x and 2x.
for base in [16, 32, 128, 256, 512] {
    try! render(size: base).write(to: URL(fileURLWithPath: "\(outputDir)/icon_\(base)x\(base).png"))
    try! render(size: base * 2).write(to: URL(fileURLWithPath: "\(outputDir)/icon_\(base)x\(base)@2x.png"))
}
print("wrote \(outputDir)")
