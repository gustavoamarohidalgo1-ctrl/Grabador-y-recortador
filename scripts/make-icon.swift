import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dist")
let iconset = root.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = base * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(size)/1024, y: CGFloat(size)/1024)
        let rect = NSRect(x: 62, y: 62, width: 900, height: 900)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 210, yRadius: 210)
        NSGradient(starting: NSColor(white: 0.16, alpha: 1),
                   ending: NSColor(white: 0.025, alpha: 1))!.draw(in: shape, angle: -60)
        NSColor.white.setStroke()
        let bracket = NSBezierPath()
        bracket.lineWidth = 42
        bracket.lineCapStyle = .round
        bracket.lineJoinStyle = .round
        let low: CGFloat = 290, high: CGFloat = 734, length: CGFloat = 115
        for (x,y,dx,dy): (CGFloat,CGFloat,CGFloat,CGFloat) in [(low,low,1,1),(high,low,-1,1),(low,high,1,-1),(high,high,-1,-1)] {
            bracket.move(to: NSPoint(x: x, y: y+dy*length))
            bracket.line(to: NSPoint(x: x, y: y))
            bracket.line(to: NSPoint(x: x+dx*length, y: y))
        }
        bracket.stroke()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 422, y: 422, width: 180, height: 180)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}
