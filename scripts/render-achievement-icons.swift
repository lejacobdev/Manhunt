import AppKit
import Foundation

// Renders one 1024x1024 PNG per Game Center achievement, in the app's own visual language:
// obsidian background, a glow and ring in the achievement's colour, and the SAME SF Symbol the
// in-app achievement list uses (the "icon" field in GameCenter/catalog.json, which is the server's).
// Run on macOS only (AppKit + SF Symbols):
//   swift scripts/render-achievement-icons.swift ios/HuntingGame/GameCenter/catalog.json out/

func color(_ hex: String) -> NSColor {
    var value: UInt64 = 0
    Scanner(string: String(hex.dropFirst())).scanHexInt64(&value)
    return NSColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: 1
    )
}

// The same palette the apps use (Shared/TacticalPalette.swift).
let obsidian = color("#090B10")
let tints: [String: NSColor] = [
    "red": color("#D93A4A"),
    "green": color("#22C55E"),
    "amber": color("#F5A524"),
    "cyan": color("#49D4FF"),
    "purple": color("#A78BFA"),
]

func render(symbol: String, tint: NSColor) -> Data? {
    let side = 1024
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ),
        let context = NSGraphicsContext(bitmapImageRep: rep)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    let full = NSRect(x: 0, y: 0, width: side, height: side)
    let centre = NSPoint(x: side / 2, y: side / 2)

    // Fully opaque square: Game Center applies its own mask, and transparency is not wanted.
    obsidian.setFill()
    full.fill()

    // Pool of colour behind the medallion.
    NSGradient(colors: [tint.withAlphaComponent(0.60), tint.withAlphaComponent(0.0)])?
        .draw(fromCenter: centre, radius: 0, toCenter: centre, radius: 560, options: [])

    // Medallion: filled disc, bold ring, faint inner hairline.
    let ringRect = full.insetBy(dx: 110, dy: 110)
    tint.withAlphaComponent(0.16).setFill()
    NSBezierPath(ovalIn: ringRect).fill()

    let ring = NSBezierPath(ovalIn: ringRect)
    ring.lineWidth = 24
    tint.setStroke()
    ring.stroke()

    let hairline = NSBezierPath(ovalIn: full.insetBy(dx: 170, dy: 170))
    hairline.lineWidth = 4
    NSColor.white.withAlphaComponent(0.14).setStroke()
    hairline.stroke()

    // The symbol, white, with a soft glow in the tint.
    let config = NSImage.SymbolConfiguration(pointSize: 400, weight: .bold)
    guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
        FileHandle.standardError.write(Data("no SF Symbol named \(symbol)\n".utf8))
        return nil
    }
    let natural = base.size
    let scale = min(1, 430 / max(natural.width, natural.height))
    let drawSize = NSSize(width: natural.width * scale, height: natural.height * scale)
    let target = NSRect(x: centre.x - drawSize.width / 2, y: centre.y - drawSize.height / 2 - 6,
                        width: drawSize.width, height: drawSize.height)

    let white = NSImage(size: natural, flipped: false) { rect in
        base.draw(in: rect)
        NSColor.white.set()
        rect.fill(using: .sourceAtop)
        return true
    }

    let glow = NSShadow()
    glow.shadowColor = tint.withAlphaComponent(0.9)
    glow.shadowBlurRadius = 70
    glow.shadowOffset = .zero
    glow.set()
    white.draw(in: target)

    return rep.representation(using: .png, properties: [:])
}

let arguments = CommandLine.arguments
guard arguments.count >= 3,
      let data = FileManager.default.contents(atPath: arguments[1]),
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let achievements = json["achievements"] as? [[String: Any]]
else {
    FileHandle.standardError.write(Data("usage: render-achievement-icons.swift catalog.json outdir\n".utf8))
    exit(2)
}

let outDir = arguments[2]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

var failed = 0
for achievement in achievements {
    guard let key = achievement["key"] as? String,
          let symbol = achievement["icon"] as? String,
          let tintName = achievement["tint"] as? String,
          let tint = tints[tintName],
          let png = render(symbol: symbol, tint: tint)
    else {
        failed += 1
        print("FAILED \(achievement["key"] as? String ?? "?")")
        continue
    }
    let path = outDir + "/" + key + ".png"
    FileManager.default.createFile(atPath: path, contents: png)
    print("rendered \(key).png  (\(symbol), \(tintName), \(png.count) bytes)")
}
exit(failed == 0 ? 0 : 1)
