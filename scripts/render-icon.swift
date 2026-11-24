import AppKit

let canvas = NSSize(width: 1024, height: 1024)
let image = NSImage(size: canvas)
image.lockFocus()
let rect = NSRect(x: 72, y: 72, width: 880, height: 880)
let background = NSBezierPath(roundedRect: rect, xRadius: 200, yRadius: 200)
NSGradient(starting: NSColor(srgbRed: 0.10, green: 0.20, blue: 0.35, alpha: 1),
           ending: NSColor(srgbRed: 0.24, green: 0.47, blue: 0.72, alpha: 1))!.draw(in: background, angle: 65)
let bars: [(CGFloat, CGFloat)] = [(278, 200), (442, 330), (606, 475)]
for (x, height) in bars {
    NSColor.white.withAlphaComponent(0.96).setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: 258, width: 116, height: height), xRadius: 36, yRadius: 36).fill()
}
let mark = NSBezierPath()
mark.move(to: NSPoint(x: 263, y: 613))
mark.line(to: NSPoint(x: 432, y: 716))
mark.line(to: NSPoint(x: 586, y: 665))
mark.line(to: NSPoint(x: 754, y: 790))
mark.lineWidth = 28
mark.lineCapStyle = .round
mark.lineJoinStyle = .round
NSColor(srgbRed: 0.61, green: 0.90, blue: 1, alpha: 1).setStroke()
mark.stroke()
image.unlockFocus()
guard CommandLine.arguments.count == 2,
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
