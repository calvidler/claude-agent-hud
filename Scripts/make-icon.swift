import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let inset: CGFloat = size * 0.09
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.2, yRadius: size * 0.2)
let gradient = NSGradient(
    starting: NSColor(calibratedRed: 0.35, green: 0.3, blue: 0.9, alpha: 1),
    ending: NSColor(calibratedRed: 0.15, green: 0.12, blue: 0.45, alpha: 1)
)
gradient?.draw(in: path, angle: -60)

let config = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .medium)
if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    NSColor.white.set()
    let symbolRect = NSRect(origin: .zero, size: symbol.size)
    symbol.draw(in: symbolRect)
    symbolRect.fill(using: .sourceAtop)
    tinted.unlockFocus()
    let drawSize = size * 0.55
    tinted.draw(in: NSRect(
        x: (size - drawSize) / 2,
        y: (size - drawSize) / 2,
        width: drawSize,
        height: drawSize
    ))
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("render failed")
}
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
