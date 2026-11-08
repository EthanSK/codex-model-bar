// swift-tools-version:5.9
// Codex Model Bar — a small macOS companion toolbar for the Codex
// (ChatGPT desktop app) window and switches the open chat's model in one click.
//
// Two targets:
//  - CodexModelBarCore: pure, testable logic (geometry, model-list parsing,
//    title matching, menu-item choice). No AppKit window/AX side effects.
//  - CodexModelBar: the actual AppKit accessory app (panel, window tracking,
//    Accessibility + synthetic keyboard driving of Codex's own model menu).
import PackageDescription

let package = Package(
    name: "CodexModelBar",
    platforms: [.macOS(.v13)],
    products: [.library(name: "CodexNativeControls", targets: ["CodexNativeControls"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(name: "CodexModelBarCore"),
        .target(name: "CodexNativeControls", dependencies: ["CodexModelBarCore"]),
        .executableTarget(
            name: "CodexModelBar",
            dependencies: ["CodexModelBarCore", "CodexNativeControls", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "CodexModelBarCoreTests",
            dependencies: ["CodexModelBarCore"]
        ),
        .testTarget(
            name: "CodexModelBarUITests",
            dependencies: ["CodexModelBar", "CodexModelBarCore", "CodexNativeControls"]
        ),
    ]
)
