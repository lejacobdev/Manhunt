import SwiftUI

/// The running figure from the app icon, as a resolution-independent shape.
///
/// This is the Font Awesome 5 Free Solid "running" glyph (U+F70C) — the exact outline the
/// app icon is built from, copied verbatim out of `ios/xtool/icon.svg` so the wordmark and
/// the icon on the home screen can't drift apart.
struct RunnerGlyph: Shape {
    private static let pathData = "M306.0 366.0Q292 352 272.0 352.0Q252 352 238.0 366.0Q224 380 224.0 400.0Q224 420 238.0 434.0Q252 448 272.0 448.0Q292 448 306.0 434.0Q320 420 320.0 400.0Q320 380 306.0 366.0ZM114 131Q126 103 152 88L162 82L154 61Q141 32 109 32H32Q19 32 9.5 41.5Q0 51 0.0 64.0Q0 77 9.5 86.5Q19 96 32 96H99ZM384 224Q397 224 406.5 214.5Q416 205 416.0 192.0Q416 179 406.5 169.5Q397 160 384 160H330Q300 160 287 187L267 228L235 150L297 114Q311 105 317.0 90.0Q323 75 318 60L287 -42Q280 -64 256 -64Q251 -64 246 -62Q234 -59 228.0 -47.0Q222 -35 225 -22L253 65L168 115Q147 128 139.5 151.0Q132 174 142 196L179 283L164 288Q151 291 139 281L99 251Q89 243 76.0 244.5Q63 246 55.0 256.5Q47 267 48.5 280.5Q50 294 61 302L100 332Q137 360 181 349L252 328Q294 317 314 277L340 224Z"

    /// The outline's tight bounds in its own coordinate space. This is a font outline, so
    /// its Y axis runs upward — hence the flip in `point(_:_:)` below.
    private static let glyphBounds = CGRect(x: 0, y: -64, width: 416, height: 512)

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let scale = min(rect.width / Self.glyphBounds.width, rect.height / Self.glyphBounds.height)
        let drawnWidth = Self.glyphBounds.width * scale
        let drawnHeight = Self.glyphBounds.height * scale
        let originX = rect.minX + (rect.width - drawnWidth) / 2
        let originY = rect.minY + (rect.height - drawnHeight) / 2

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: originX + (x - Self.glyphBounds.minX) * scale,
                y: originY + (Self.glyphBounds.maxY - y) * scale
            )
        }

        let chars = Array(Self.pathData)
        var index = 0
        var command: Character = " "

        func readNumber() -> CGFloat? {
            while index < chars.count, chars[index] == " " || chars[index] == "," { index += 1 }
            var text = ""
            if index < chars.count, chars[index] == "-" {
                text.append("-")
                index += 1
            }
            while index < chars.count, chars[index].isNumber || chars[index] == "." {
                text.append(chars[index])
                index += 1
            }
            guard let value = Double(text) else { return nil }
            return CGFloat(value)
        }

        while index < chars.count {
            let char = chars[index]
            if char == " " || char == "," {
                index += 1
                continue
            }
            // H is the one horizontal-lineto in this outline; everything else is M/L/Q/Z.
            if "MLQZH".contains(char) {
                command = char
                index += 1
                if char == "Z" {
                    path.closeSubpath()
                    continue
                }
            }

            switch command {
            case "M":
                guard let x = readNumber(), let y = readNumber() else { return path }
                path.move(to: point(x, y))
            case "L":
                guard let x = readNumber(), let y = readNumber() else { return path }
                path.addLine(to: point(x, y))
            case "H":
                guard let x = readNumber(), let current = path.currentPoint else { return path }
                path.addLine(to: CGPoint(x: point(x, 0).x, y: current.y))
            case "Q":
                guard let cx = readNumber(), let cy = readNumber(),
                      let x = readNumber(), let y = readNumber() else { return path }
                path.addQuadCurve(to: point(x, y), control: point(cx, cy))
            default:
                index += 1
            }
        }

        return path
    }
}

/// "HUNTING GAME" with the app icon's runner standing in for the A.
struct HuntingGameWordmark: View {
    var size: CGFloat
    var glyphTint: Color = ADATheme.runnerGreen

    /// Cap height of SF Pro Rounded is a shade under three quarters of the point size; the
    /// glyph is matched to it so it sits as a letter rather than an inline picture.
    private var glyphHeight: CGFloat { size * 0.74 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("HUNTING G")
            RunnerGlyph()
                .fill(glyphTint)
                .frame(width: glyphHeight * (416.0 / 512.0), height: glyphHeight)
                .shadow(color: glyphTint.opacity(0.55), radius: size * 0.35)
                // Sits the glyph's feet on the text baseline, the way the A it replaces would.
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                .padding(.horizontal, size * 0.055)
            Text("ME")
        }
        .font(ADATheme.displayFont(size: size))
        .foregroundColor(.white)
    }
}
