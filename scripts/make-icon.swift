// Draws the app icon: a price tag with a falling-price arrow on a green tile.
// No Steam logo or Valve mark anywhere; the colors are just colors.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS icon grid: 824pt tile centred on a 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0x0F4A2A)); ctx.fillPath()
ctx.restoreGState()

// Tile gradient: fresh green at the top to deep forest at the bottom.
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x3FBF74), rgb(0x176B3E)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xC9F5D9, 0.35), rgb(0xC9F5D9, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 420, y: 640), startRadius: 0,
                       endCenter: CGPoint(x: 420, y: 640), endRadius: 460, options: [])
ctx.restoreGState()

// Price tag: a rounded rectangle with one pointed end, tilted, with a punched hole and string.
let tag = CGMutablePath()
let w: CGFloat = 520, h: CGFloat = 330, r: CGFloat = 48, tip: CGFloat = 130
let left = CGPoint(x: -w / 2, y: 0)
tag.move(to: CGPoint(x: left.x + tip, y: h / 2))
tag.addLine(to: CGPoint(x: w / 2 - r, y: h / 2))
tag.addArc(tangent1End: CGPoint(x: w / 2, y: h / 2), tangent2End: CGPoint(x: w / 2, y: h / 2 - r), radius: r)
tag.addLine(to: CGPoint(x: w / 2, y: -h / 2 + r))
tag.addArc(tangent1End: CGPoint(x: w / 2, y: -h / 2), tangent2End: CGPoint(x: w / 2 - r, y: -h / 2), radius: r)
tag.addLine(to: CGPoint(x: left.x + tip, y: -h / 2))
tag.addArc(tangent1End: left, tangent2End: CGPoint(x: left.x + tip, y: h / 2), radius: 40)
tag.closeSubpath()

var tilt = CGAffineTransform(translationX: 530, y: 500).rotated(by: .pi / 9)
let tagPath = tag.copy(using: &tilt)!
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.4))
ctx.addPath(tagPath); ctx.setFillColor(rgb(0xFFFBF2)); ctx.fillPath()
ctx.restoreGState()

// Hole near the pointed end, with a short loop of string.
let hole = CGPoint(x: left.x + tip + 10, y: 0).applying(tilt)
ctx.setFillColor(rgb(0x176B3E))
ctx.fillEllipse(in: CGRect(x: hole.x - 34, y: hole.y - 34, width: 68, height: 68))
ctx.setStrokeColor(rgb(0xFFFBF2)); ctx.setLineWidth(22); ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: hole.x - 10, y: hole.y + 20))
ctx.addCurve(to: CGPoint(x: hole.x - 150, y: hole.y + 140), control1: CGPoint(x: hole.x - 60, y: hole.y + 110),
             control2: CGPoint(x: hole.x - 120, y: hole.y + 170))
ctx.strokePath()

// Falling-price arrow on the tag, in the tile's green.
let arrow = CGMutablePath()
let ax: CGFloat = 90, top: CGFloat = 120, aw: CGFloat = 150
arrow.move(to: CGPoint(x: ax, y: -top))
arrow.addLine(to: CGPoint(x: ax + aw / 2, y: -top + 95))
arrow.addLine(to: CGPoint(x: ax + aw / 5, y: -top + 95))
arrow.addLine(to: CGPoint(x: ax + aw / 5, y: top))
arrow.addLine(to: CGPoint(x: ax - aw / 5, y: top))
arrow.addLine(to: CGPoint(x: ax - aw / 5, y: -top + 95))
arrow.addLine(to: CGPoint(x: ax - aw / 2, y: -top + 95))
arrow.closeSubpath()
let rounded = arrow.copy(strokingWithWidth: 22, lineCap: .round, lineJoin: .round, miterLimit: 10).union(arrow)
ctx.addPath(rounded.copy(using: &tilt)!); ctx.setFillColor(rgb(0x1E8A4C)); ctx.fillPath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
