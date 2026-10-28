// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemoKit",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "MemoKit", targets: ["MemoKit"]),
    ],
    targets: [
        .target(name: "MemoKit"),
        .testTarget(name: "MemoKitTests", dependencies: ["MemoKit"]),
    ],
    swiftLanguageModes: [.v6]
)
