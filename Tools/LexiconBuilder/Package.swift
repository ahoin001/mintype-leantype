// swift-tools-version: 6.0
import PackageDescription

/// Build-time tool that compiles a frequency list into `lexicon.bin`. Never ships in the app.
let package = Package(
    name: "LexiconBuilder",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/LeanTypeKit"),
    ],
    targets: [
        .executableTarget(
            name: "LexiconBuilder",
            dependencies: [.product(name: "LeanTypeCore", package: "LeanTypeKit")]
        ),
    ]
)
