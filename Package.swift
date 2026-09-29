// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EasyDL",
    platforms: [.macOS("14.0")],
    targets: [
        .executableTarget(
            name: "EasyDL",
            path: "Sources/EasyDL",
            swiftSettings: [
                .unsafeFlags(["-O", "-whole-module-optimization"], .when(configuration: .release))
            ]
        )
    ]
)
