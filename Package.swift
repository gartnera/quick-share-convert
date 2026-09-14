// swift-tools-version:6.0
import PackageDescription

// The portable core (models + conversion engine) lives here so it can be built
// and tested natively on macOS — `swift test` needs no iOS simulator — and
// reused unchanged by the future macOS app. The iOS app, share extension, and
// this package all compile the same sources under ConvertKit/Sources.
let package = Package(
    name: "ConvertKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ConvertKit", targets: ["ConvertKit"]),
    ],
    targets: [
        .target(
            name: "ConvertKit",
            path: "ConvertKit/Sources"
        ),
        .testTarget(
            name: "ConvertKitTests",
            dependencies: ["ConvertKit"],
            path: "ConvertKitTests"
        ),
    ],
    // Match the app targets (project.yml SWIFT_VERSION = 5.0); avoids Swift 6
    // strict-concurrency churn in the AVFoundation callback code for now.
    swiftLanguageModes: [.v5]
)
