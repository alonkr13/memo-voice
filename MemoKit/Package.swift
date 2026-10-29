// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemoKit",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "MemoKit", targets: ["MemoKit"]),
    ],
    targets: [
        .target(name: "MemoKit", dependencies: ["whisper"]),
        // whisper.cpp v1.9.5 (commit d1be6fd): the release's XCFramework is attached to its
        // nightly build b5454. Dynamic framework, embedded into Memo.app/Frameworks by Xcode.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
        ),
        .testTarget(name: "MemoKitTests", dependencies: ["MemoKit"]),
    ],
    swiftLanguageModes: [.v6]
)
