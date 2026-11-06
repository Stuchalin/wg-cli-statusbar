// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WGStatusBar",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(
            name: "WGStatusBar",
            targets: ["WGStatusBar"]
        ),
        .executable(
            name: "WGStatusBarHelper",
            targets: ["WGStatusBarHelper"]
        ),
        .library(
            name: "WGStatusBarCore",
            targets: ["WGStatusBarCore"]
        )
    ],
    targets: [
        .target(name: "ConfigEditPOSIX", path: "Sources/ConfigEditPOSIX", publicHeadersPath: "include"),
        .target(
            name: "WGStatusBarCore",
            dependencies: ["ConfigEditPOSIX"],
            path: "Sources/WGStatusBarCore",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "WGStatusBar",
            dependencies: ["WGStatusBarCore"],
            path: "Sources/App"
        ),
        .executableTarget(
            name: "WGStatusBarHelper",
            dependencies: ["WGStatusBarCore"],
            path: "Sources/Helper"
        ),
        .testTarget(
            name: "WGStatusBarTests",
            dependencies: ["WGStatusBarCore", "ConfigEditPOSIX"],
            path: "Tests"
        ),
    ]
)
