// swift-tools-version: 6.0
// This package exists solely so `xtool` (https://xtool.sh) can build HuntingGame
// on Linux/Windows without Xcode. It does NOT replace ios/HuntingGame/project.yml —
// that XcodeGen project remains the full-featured build (includes the watchOS
// companion app, which xtool has no documented support for) for use on a Mac via
// build_ipa.sh. Every source file here is a symlink into ios/HuntingGame/, so the
// two build paths share one copy of the code; nothing is duplicated.
//
// Sources/HuntingGame/ and Sources/HuntingGameWidget/ are each a real directory
// (not a symlink) containing subfolder-level symlinks into ios/HuntingGame/'s
// Sources/, Shared/, and LiveActivityShared/ folders. This mirrors exactly what
// Xcode does when the same folder is listed under multiple targets: each target
// gets its own independently-compiled copy of that source, with no import needed
// and no module boundary between them — the code was written for that model, not
// SwiftPM's (a first attempt split Shared/LiveActivityShared into their own
// SwiftPM library targets, which are genuinely separate modules; every reference
// to a shared type failed with "cannot find X in scope" since nothing in this
// codebase imports them, and it isn't `public` throughout).
//
// See README.md in this directory for setup and known limitations.

import PackageDescription

// The actual source (symlinked from ios/HuntingGame/) was written against
// project.yml's SWIFT_VERSION 5.0 — plain Swift 5 language mode — but this
// package needs swift-tools-version 6.0 for xtool's app-extension product
// support, which defaults targets to Swift 6's stricter concurrency checking.
// Pinning back to .v5 matches what the code actually targets.
let swift5Mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "HuntingGame",
    platforms: [
        // Matches ios/HuntingGame/project.yml's deploymentTarget — ActivityKit's
        // ActivityContent-based request/update API requires 16.2+. IOSVersion is
        // ExpressibleByStringLiteral, so a point release can be spelled directly.
        .iOS("16.2"),
    ],
    products: [
        // An xtool project needs exactly one library product per app/extension
        // bundle. xtool.yml wires "HuntingGame" as the app and "HuntingGameWidget"
        // as its widget/Live Activity extension.
        .library(name: "HuntingGame", targets: ["HuntingGame"]),
        .library(name: "HuntingGameWidget", targets: ["HuntingGameWidget"]),
    ],
    dependencies: [
        // Matches project.yml's `packages.SocketIO`.
        .package(url: "https://github.com/socketio/socket.io-client-swift", from: "16.1.1"),
    ],
    targets: [
        .target(
            name: "HuntingGame",
            dependencies: [
                .product(name: "SocketIO", package: "socket.io-client-swift"),
            ],
            swiftSettings: swift5Mode
        ),

        .target(
            name: "HuntingGameWidget",
            swiftSettings: swift5Mode
        ),
    ]
)
