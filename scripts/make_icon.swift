// Renders Echo's app icon: mesh-cyan waveform on flat studio grey ("3D Sculpt"
// system — flat on purpose). Usage: swift scripts/make_icon.swift <output.png>
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
NSColor(red: 0.137, green: 0.137, blue: 0.153, alpha: 1).setFill() // #232327
squircle.fill()

NSColor(red: 0.0, green: 0.749, blue: 0.812, alpha: 1).setFill() // #00BFCF
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
