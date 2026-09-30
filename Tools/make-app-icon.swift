// Draws FileCat's app icon.
// Usage: xcrun swift Tools/make-app-icon.swift FileCat/FileCat/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import AppKit
import UniformTypeIdentifiers

let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let full = CGRect(x: 0, y: 0, width: size, height: size)
let gradient = NSGradient(starting: NSColor(srgbRed: 0.35, green: 0.70, blue: 1.0, alpha: 1),
                          ending: NSColor(srgbRed: 0.0, green: 0.40, blue: 0.95, alpha: 1))!
gradient.draw(in: full, angle: -90)

// Folder, exactly as before.
let config = NSImage.SymbolConfiguration(pointSize: 560, weight: .regular).applying(.init(paletteColors: [.white]))
let symbol = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
let s = symbol.size
symbol.draw(in: NSRect(x: (CGFloat(size) - s.width) / 2, y: (CGFloat(size) - s.height) / 2 - 10, width: s.width, height: s.height))

// Cat head, cut out of the folder body so the background gradient shows through.
// Coordinates are bottom-up; the folder body spans roughly y 254...599, x 200...822.
let cx: CGFloat = 512, cy: CGFloat = 396
func cutout(_ path: CGPath) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    gradient.draw(in: full, angle: -90)
    ctx.restoreGState()
}
// Head: a slightly wide, soft oval.
cutout(CGPath(ellipseIn: CGRect(x: cx - 136, y: cy - 100, width: 272, height: 200), transform: nil))
// Ears: triangles with rounded tips, leaning outward.
for side: CGFloat in [-1, 1] {
    let ear = CGMutablePath()
    ear.move(to: CGPoint(x: cx + side * 112, y: cy + 30))
    ear.addLine(to: CGPoint(x: cx + side * 128, y: cy + 152))
    ear.addLine(to: CGPoint(x: cx + side * 30, y: cy + 84))
    ear.closeSubpath()
    // Fill plus a round-joined stroke of the same shape softens the corners.
    cutout(ear)
    cutout(ear.copy(strokingWithWidth: 22, lineCap: .round, lineJoin: .round, miterLimit: 1))
}

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
