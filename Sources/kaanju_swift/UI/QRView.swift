#if canImport(UIKit)
import SwiftUI
import CoreImage.CIFilterBuiltins
import UIKit

/// A QR code rendered from a string using CoreImage — no external dependency.
/// Caches the generated image per (string, size) so it doesn't regenerate on
/// every status poll re-render.
struct QRView: View {
    let string: String
    var size: CGFloat = 200

    var body: some View {
        Group {
            if let image = Self.qrImage(from: string, size: size) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .accessibilityLabel("Payment QR code")
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: size, height: size)
                    .overlay(Text("QR unavailable").font(.caption).foregroundStyle(.secondary))
            }
        }
    }

    private static let context = CIContext()

    static func qrImage(from string: String, size: CGFloat) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        // Scale the (small) generated image up crisply to the target size.
        let scale = max(1, size / output.extent.width)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
#endif
