// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Zuuppa_Swift_SDK",
    platforms: [
        .iOS(.v17),
        // The checkout UI is iOS-only (UIKit-gated). macOS is declared only so
        // the model/decoding unit tests can run on a dev machine via `swift test`.
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "Zuuppa_Swift_SDK",
            targets: ["Zuuppa_Swift_SDK"]
        ),
    ],
    targets: [
        // Zero external dependencies: the QR code is rendered with CoreImage,
        // networking with URLSession. Nothing to resolve. The bundled asset
        // catalog carries the brand color sets (light + dark), loaded via
        // `Bundle.module` in `ZuuppaColor`.
        .target(
            name: "Zuuppa_Swift_SDK",
            resources: [.process("Resources/ZuuppaColors.xcassets")]
        ),
        .testTarget(
            name: "Zuuppa_Swift_SDKTests",
            dependencies: ["Zuuppa_Swift_SDK"]
        ),
    ]
)
