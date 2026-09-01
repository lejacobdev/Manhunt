// swift-tools-version: 6.0
// This package exists solely so `xtool` (https://xtool.sh) can build HuntingGame
// on Linux/Windows without Xcode. It does NOT replace ios/HuntingGame/project.yml —
// that XcodeGen project remains the full-featured build (includes the watchOS
// companion app, which xtool has no documented support for) for use on a Mac via
// build_ipa.sh. Every source file here is a symlink into ios/HuntingGame/, so the
// two build paths share one copy of the code; nothing is duplicated.
//
// See README.md in this directory for setup and known limitations.

import PackageDescription

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
        // Mirrors project.yml's Shared/ folder (compiled into both the app and
        // the widget extension so both agree on colors and the WatchConnectivity
        // payload shape — the payload type itself is harmless to keep even
        // though the watchOS app isn't part of this build).
        .target(name: "HuntingGameShared"),

        // Mirrors project.yml's LiveActivityShared/ folder — the ActivityAttributes
        // type both the app and the widget extension need to agree on.
        .target(name: "LiveActivityShared"),

        .target(
            name: "HuntingGame",
            dependencies: [
                "HuntingGameShared",
                "LiveActivityShared",
                .product(name: "SocketIO", package: "socket.io-client-swift"),
            ]
        ),

        .target(
            name: "HuntingGameWidget",
            dependencies: [
                "HuntingGameShared",
                "LiveActivityShared",
            ]
        ),
    ]
)
