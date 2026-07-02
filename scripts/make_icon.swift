// Renders Echo's app icon: coral waveform on a graphite gradient, Big Sur-style
// rounded square. Usage: swift scripts/make_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let inset: CGFloat = 100
let squircle = NSBezierPath(
    roundedRect: NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2),
    xRadius: 185,
    yRadius: 185
)
let top = NSColor(red: 0.196, green: 0.192, blue: 0.224, alpha: 1)
let bottom = NSColor(red: 0.090, green: 0.086, blue: 0.110, alpha: 1)
NSGradient(starting: top, ending: bottom)!.draw(in: squircle, angle: -90)

NSColor(red: 1.0, green: 0.36, blue: 0.36, alpha: 1).setFill()
let heights: [CGFloat] = [0.30, 0.55, 0.85, 1.0, 0.72, 0.45, 0.26]
let barWidth: CGFloat = 52
let spacing: CGFloat = 40
let maxBar: CGFloat = 400
var x = (size - (CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * spacing)) / 2
for fraction in heights {
    let barHeight = maxBar * fraction
    NSBezierPath(
        roundedRect: NSRect(x: x, y: (size - barHeight) / 2, width: barWidth, height: barHeight),
        xRadius: barWidth / 2,
        yRadius: barWidth / 2
    ).fill()
    x += barWidth + spacing
}

image.unlockFocus()

guard CommandLine.arguments.count > 1,
      let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("usage: swift make_icon.swift <output.png>")
}
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
