// swift-tools-version: 6.2
// GlyphCore: the one thing the Glyph apps (Studio, Dictate, Mobile, Record, Code) share.
// No app code, no UI, no dependency on any app. Three products, so an app links only
// what it uses:
//   GlyphVault    the plain-file vault (docs/vault-format.md): read, write, links,
//                 suggestions, search, tasks, a Library that follows the disk
//   GlyphCapture  recording (mic + system audio to .m4a) and on-device transcription
//   GlyphAI       summaries and heard names with Apple's on-device model
// GlyphCore re-exports all three. Version: VERSION; changes: CHANGELOG.md.
import PackageDescription

let package = Package(
    name: "GlyphCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "GlyphVault", targets: ["GlyphVault"]),
        .library(name: "GlyphCapture", targets: ["GlyphCapture"]),
        .library(name: "GlyphAI", targets: ["GlyphAI"]),
        .library(name: "GlyphCore", targets: ["GlyphCore"]),
        .executable(name: "glyphcore-report", targets: ["glyphcore-report"]),
    ],
    targets: [
        .target(name: "GlyphVault"),
        .target(name: "GlyphCapture", dependencies: ["GlyphVault"]),
        .target(name: "GlyphAI", dependencies: ["GlyphVault"]),
        .target(name: "GlyphCore", dependencies: ["GlyphVault", "GlyphCapture", "GlyphAI"]),
        .executableTarget(name: "glyphcore-report", dependencies: ["GlyphVault"]),
        .testTarget(name: "GlyphVaultTests", dependencies: ["GlyphVault"], resources: [.copy("Fixtures"), .copy("Golden")]),
        .testTarget(name: "GlyphCaptureTests", dependencies: ["GlyphCapture"]),
        .testTarget(name: "GlyphAITests", dependencies: ["GlyphAI"]),
    ]
)
