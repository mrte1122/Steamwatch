// Renders a programmatic fallback card (1280×640) to docs/social-preview-generated.png. The card
// actually used, docs/social-preview.png, is designed in Canva; this keeps a quick way to rebuild one.
// Usage: swift scripts/make-social-preview.swift   (then upload it in the repo's Settings → Social preview)
import AppKit

let W: CGFloat = 1280, H: CGFloat = 640, scale: CGFloat = 1   // GitHub caps the upload at 1 MB
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
guard let icon = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.png")),
      let shot = NSImage(contentsOf: root.appendingPathComponent("docs/popover-dark.png")) else {
    print("run from the repo root"); exit(1)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background: the icon's green → deep forest gradient.
NSGradient(starting: NSColor(srgbRed: 0.18, green: 0.56, blue: 0.33, alpha: 1),
           ending: NSColor(srgbRed: 0.03, green: 0.14, blue: 0.08, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -60)

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat = 1, at p: NSPoint, width: CGFloat = 640) {
    let style = NSMutableParagraphStyle(); style.lineSpacing = 4
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                .foregroundColor: NSColor.white.withAlphaComponent(alpha),
                                                .paragraphStyle: style]
    let r = (s as NSString).boundingRect(with: NSSize(width: width, height: 400), options: .usesLineFragmentOrigin, attributes: attrs)
    (s as NSString).draw(with: NSRect(x: p.x, y: p.y - r.height, width: width, height: r.height),
                         options: .usesLineFragmentOrigin, attributes: attrs)
}

// GitHub's repo-card template: keep everything important 80 px in from every edge (it gets
// cropped differently depending on where the link is shared). Only the background bleeds.
let safe = NSRect(x: 80, y: 80, width: W - 160, height: H - 160)

// Right: the top of the popover (tabs, filters, target hits and deals), with a soft shadow.
let crop = NSRect(x: 0, y: shot.size.height * 0.30, width: shot.size.width, height: shot.size.height * 0.70)
let shotH = safe.height
let shotW = crop.width / crop.height * shotH
let frame = NSRect(x: safe.maxX - shotW, y: safe.minY, width: shotW, height: shotH)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -8)
shadow.shadowColor = NSColor.black.withAlphaComponent(0.5); shadow.set()
shot.draw(in: frame, from: crop, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

// Left column: icon and name, pitch, footer, all inside the safe area.
let textWidth = frame.minX - safe.minX - 40
icon.draw(in: NSRect(x: safe.minX, y: safe.maxY - 120, width: 120, height: 120))
text("Vaporwatch", size: 64, weight: .bold, at: NSPoint(x: safe.minX + 140, y: safe.maxY - 18))
text("Never miss a Steam sale.", size: 38, weight: .semibold, at: NSPoint(x: safe.minX, y: safe.maxY - 160), width: textWidth)
text("Your wishlist's deals, price limits that notify you, new lows and games you might like, in your Mac's menu bar.",
     size: 24, weight: .regular, alpha: 0.78, at: NSPoint(x: safe.minX, y: safe.maxY - 225), width: textWidth)
text("Free and open source  ·  Notarized  ·  github.com/mrte1122/Vaporwatch", size: 19, weight: .medium, alpha: 0.6,
     at: NSPoint(x: safe.minX, y: safe.minY + 26), width: textWidth)

NSGraphicsContext.restoreGraphicsState()
let out = root.appendingPathComponent("docs/social-preview-generated.png")
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("Wrote \(out.path)")
