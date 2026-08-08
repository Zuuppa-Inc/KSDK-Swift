// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "kaanju_swift",
    platforms: [
        .iOS(.v17),
        // The checkout UI is iOS-only (UIKit-gated). macOS is declared only so
        // the model/decoding unit tests can run on a dev machine via `swift test`.
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "kaanju_swift",
            targets: ["kaanju_swift"]
        ),
    ],
    targets: [
        // Zero external dependencies: the QR code is rendered with CoreImage,
        // networking with URLSession. Nothing to resolve.
        .target(
            name: "kaanju_swift"
        ),
        .testTarget(
            name: "kaanju_swiftTests",
            dependencies: ["kaanju_swift"]
        ),
    ]
)
