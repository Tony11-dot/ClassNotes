// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "ClassMateTheme",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "ClassMateTheme", targets: ["ClassMateTheme"])
    ],
    targets: [
        .target(
            name: "ClassMateTheme",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ClassMateThemeTests",
            dependencies: ["ClassMateTheme"]
        )
    ]
)
