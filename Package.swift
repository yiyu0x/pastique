// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pastique",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Pastique", targets: ["Pastique"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Pastique",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Pastique"
        ),
        .testTarget(
            name: "PastiqueTests",
            dependencies: ["Pastique"],
            path: "Tests/PastiqueTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
