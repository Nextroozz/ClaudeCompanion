// swift-tools-version: 5.9
// ─────────────────────────────────────────────────────────────────────────────
// ClaudeCompanion — wrapper SwiftUI natif pour le CLI « claude » (Claude Code)
//
// Ce Package.swift permet de lancer l'app immédiatement avec `swift run`
// (pratique pour le développement). Pour une vraie app distribuable (.app),
// créez un projet Xcode « macOS App » et glissez-y le dossier Sources/
// — voir README.md, section « Créer le bundle .app ».
// ─────────────────────────────────────────────────────────────────────────────
import PackageDescription

let package = Package(
    name: "ClaudeCompanion",
    platforms: [
        // macOS 14 minimum : Swift Concurrency mature, TextField(axis:),
        // onChange(of:) moderne. L'effet Liquid Glass natif (macOS 26) est
        // activé dynamiquement via #available — repli NSVisualEffectView sinon.
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ClaudeCompanion",
            path: "Sources/ClaudeCompanion"
        ),
        .testTarget(
            name: "ClaudeCompanionTests",
            dependencies: ["ClaudeCompanion"],
            path: "Tests/ClaudeCompanionTests"
        ),
    ]
)
