// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "swift-vim-engine",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "VimEngine", targets: ["VimEngine"])
    ],
    targets: [
        .target(
            name: "VimEngine",
            path: "Sources/VimEngine"
        ),
        .executableTarget(
            name: "VimEngineTests",
            dependencies: ["VimEngine"],
            path: "Tests/VimEngineTests"
        )
    ]
)
