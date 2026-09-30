// Draws MusiCat's app icon: a white vinyl record on a gradient, like FileCat's white folder, with
// the centre hole cut in the shape of FileCat's cat head.
// Usage: xcrun swift Tools/make-musicat-icon.swift MusiCat/MusiCat/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import AppKit
import UniformTypeIdentifiers

let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let full = CGRect(x: 0, y: 0, width: size, height: size)
// Same light-to-deep vertical gradient as FileCat, in violet instead of blue.
let gradient = NSGradient(starting: NSColor(srgbRed: 0.78, green: 0.45, blue: 1.0, alpha: 1),
                          ending: NSColor(srgbRed: 0.45, green: 0.12, blue: 0.92, alpha: 1))!
gradient.draw(in: full, angle: -90)

func cutout(_ path: CGPath, alpha: CGFloat = 1) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.setAlpha(alpha)
    gradient.draw(in: full, angle: -90)
    ctx.restoreGState()
}

let cx: CGFloat = 512, cy: CGFloat = 512

// The record.
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillEllipse(in: CGRect(x: cx - 350, y: cy - 350, width: 700, height: 700))

// Grooves: thin rings letting a little of the background through.
for radius: CGFloat in [318, 290, 262, 234] {
    let ring = CGPath(ellipseIn: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2), transform: nil)
        .copy(strokingWithWidth: 5, lineCap: .round, lineJoin: .round, miterLimit: 1)
    cutout(ring, alpha: 0.35)
}
// The label: a ring around the hole.
let label = CGPath(ellipseIn: CGRect(x: cx - 176, y: cy - 176, width: 352, height: 352), transform: nil)
    .copy(strokingWithWidth: 10, lineCap: .round, lineJoin: .round, miterLimit: 1)
cutout(label, alpha: 0.55)

// The hole: FileCat's cat head, the same proportions a little smaller, centred on the record.
let headY = cy - 26
cutout(CGPath(ellipseIn: CGRect(x: cx - 122, y: headY - 90, width: 244, height: 180), transform: nil))
for side: CGFloat in [-1, 1] {
    let ear = CGMutablePath()
    ear.move(to: CGPoint(x: cx + side * 100, y: headY + 27))
    ear.addLine(to: CGPoint(x: cx + side * 115, y: headY + 137))
    ear.addLine(to: CGPoint(x: cx + side * 27, y: headY + 76))
    ear.closeSubpath()
    cutout(ear)
    cutout(ear.copy(strokingWithWidth: 20, lineCap: .round, lineJoin: .round, miterLimit: 1))
}

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
