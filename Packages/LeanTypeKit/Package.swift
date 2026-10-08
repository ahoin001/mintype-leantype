// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LeanTypeKit",
    // macOS only so build tools (Tools/LexiconBuilder) and host-side benchmarks can use Core.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LeanTypeCore", targets: ["LeanTypeCore"]),
        .library(name: "LeanTypeDesign", targets: ["LeanTypeDesign"]),
        .library(name: "LeanTypeKeyboardUI", targets: ["LeanTypeKeyboardUI"]),
    ],
    targets: [
        .target(name: "LeanTypeCore", resources: [.copy("Resources/lexicon.bin")]),
        .target(name: "LeanTypeDesign", dependencies: ["LeanTypeCore"]),
        .target(name: "LeanTypeKeyboardUI", dependencies: ["LeanTypeCore", "LeanTypeDesign"]),
        .testTarget(name: "LeanTypeCoreTests", dependencies: ["LeanTypeCore", "LeanTypeDesign"]),
    ]
)
