// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "NotesKit",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "NotesModels", targets: ["NotesModels"]),
        .library(name: "NotesServices", targets: ["NotesServices"]),
        .library(name: "NotesDesignSystem", targets: ["NotesDesignSystem"]),
        .library(name: "NotesPaywall", targets: ["NotesPaywall"]),
        .library(name: "NotesAI", targets: ["NotesAI"]),
        .library(name: "NotesLibrary", targets: ["NotesLibrary"]),
        .library(name: "NotesEditor", targets: ["NotesEditor"])
    ],
    dependencies: [
        .package(path: "../ClassMateTheme"),
        // The launch animation is the designed Lottie scene itself
        // (`Resources/LaunchScene.json`), not a hand-rebuilt approximation of it.
        // This is the one third-party dependency in the app.
        .package(url: "https://github.com/airbnb/lottie-ios.git", from: "4.5.0")
    ],
    targets: [
        .target(
            name: "NotesModels",
            dependencies: ["ClassMateTheme"]
        ),
        .target(
            name: "NotesServices",
            dependencies: ["NotesModels", "ClassMateTheme"]
        ),
        .target(
            name: "NotesDesignSystem",
            dependencies: [
                "ClassMateTheme", "NotesModels", "NotesServices",
                .product(name: "Lottie", package: "lottie-ios")
            ],
            resources: [.process("Resources")]
        ),
        .target(
            name: "NotesPaywall",
            dependencies: ["NotesServices", "NotesDesignSystem", "ClassMateTheme"]
        ),
        .target(
            name: "NotesAI",
            dependencies: ["NotesServices", "NotesDesignSystem", "NotesModels", "ClassMateTheme"]
        ),
        .target(
            name: "NotesLibrary",
            dependencies: [
                "NotesModels", "NotesServices", "NotesDesignSystem",
                "NotesPaywall", "NotesAI", "ClassMateTheme"
            ]
        ),
        .target(
            name: "NotesEditor",
            dependencies: [
                "NotesModels", "NotesServices", "NotesDesignSystem",
                "NotesAI", "ClassMateTheme"
            ]
        ),
        .testTarget(
            name: "NotesKitTests",
            dependencies: [
                "NotesModels", "NotesServices", "NotesDesignSystem",
                "NotesPaywall", "NotesAI", "NotesLibrary", "NotesEditor", "ClassMateTheme"
            ]
        )
    ]
)
