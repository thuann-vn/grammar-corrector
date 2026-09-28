// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GrammarCorrector",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GrammarCorrector",
            path: "Sources/GrammarCorrector"
        )
    ]
)
