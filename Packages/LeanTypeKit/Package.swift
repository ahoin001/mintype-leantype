// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LeanTypeKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "LeanTypeCore", targets: ["LeanTypeCore"]),
        .library(name: "LeanTypeDesign", targets: ["LeanTypeDesign"]),
        .library(name: "LeanTypeKeyboardUI", targets: ["LeanTypeKeyboardUI"]),
    ],
    targets: [
        .target(name: "LeanTypeCore"),
        .target(name: "LeanTypeDesign", dependencies: ["LeanTypeCore"]),
        .target(name: "LeanTypeKeyboardUI", dependencies: ["LeanTypeCore", "LeanTypeDesign"]),
        .testTarget(name: "LeanTypeCoreTests", dependencies: ["LeanTypeCore"]),
    ]
)
