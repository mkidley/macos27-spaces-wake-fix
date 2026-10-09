import AppKit
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let background = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 190, yRadius: 190)
        NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.58, blue: 0.94, alpha: 1), ending: NSColor(calibratedRed: 0.14, green: 0.25, blue: 0.66, alpha: 1))!.draw(in: background, angle: -90)
        for index in 0..<3 {
            let frame = NSRect(x: 215 + CGFloat(index) * 70, y: 465 - CGFloat(index) * 105, width: 455, height: 285)
            let pane = NSBezierPath(roundedRect: frame, xRadius: 32, yRadius: 32)
            NSColor(calibratedRed: 0.20, green: 0.40, blue: 0.77, alpha: 1).setFill(); pane.fill()
            NSColor.white.withAlphaComponent(0.7 + CGFloat(index) * 0.15).setStroke(); pane.lineWidth = 23; pane.stroke()
            let line = NSBezierPath(); line.move(to: NSPoint(x: frame.minX + 12, y: frame.maxY - 61)); line.line(to: NSPoint(x: frame.maxX - 12, y: frame.maxY - 61)); line.lineWidth = 13; line.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
