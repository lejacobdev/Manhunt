import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Renders a string as a scannable QR code. Deliberately drawn dark-on-white inside its own
/// light card even though the rest of the app is near-black: inverted codes are a coin flip
/// across scanner implementations, and this one has to survive being read by a stranger's
/// stock Camera app, not just our own scanner.
struct QRCodeView: View {
    let payload: String
    var size: CGFloat = 220

    var body: some View {
        Group {
            if let image = Self.render(payload) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: size * 0.5))
                    .foregroundColor(.black.opacity(0.3))
            }
        }
        .frame(width: size, height: size)
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: ADATheme.cardCornerRadius, style: .continuous))
    }

    private static let context = CIContext()

    static func render(_ string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        // "M" tolerates ~15% damage — enough for a phone screen photographed at an angle
        // without inflating the module count the way "Q"/"H" would on a long URL.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // The generator emits one pixel per module; scaling up before rasterizing (with
        // .interpolation(.none) above) keeps the edges crisp instead of blurring them.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
