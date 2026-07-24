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
        .library(name: "NotesLibrary", targets: ["NotesLibrary"]),
        .library(name: "NotesEditor", targets: ["NotesEditor"])
    ],
    dependencies: [
        .package(path: "../ClassMateTheme")
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
            dependencies: ["ClassMateTheme", "NotesModels"]
        ),
        .target(
            name: "NotesPaywall",
            dependencies: ["NotesServices", "NotesDesignSystem", "ClassMateTheme"]
        ),
        .target(
            name: "NotesLibrary",
            dependencies: [
                "NotesModels", "NotesServices", "NotesDesignSystem",
                "NotesPaywall", "ClassMateTheme"
            ]
        ),
        .target(
            name: "NotesEditor",
            dependencies: [
                "NotesModels", "NotesServices", "NotesDesignSystem", "ClassMateTheme"
            ]
        ),
        .testTarget(
            name: "NotesKitTests",
            dependencies: [
                "NotesModels", "NotesServices", "NotesDesignSystem",
                "NotesPaywall", "NotesLibrary", "NotesEditor", "ClassMateTheme"
            ]
        )
    ]
)
