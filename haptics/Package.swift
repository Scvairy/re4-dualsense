// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RE4Haptics",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "re4-haptics", targets: ["RE4Haptics"])],
    dependencies: [
        .package(url: "https://github.com/theisegoria/tactile.git",
                 revision: "160181f63f6a51f623aa1f6d5a45587ca2d5514c"),
    ],
    targets: [
        .executableTarget(name: "RE4Haptics", dependencies: [
            .product(name: "Tactile", package: "tactile"),
        ]),
    ]
)
