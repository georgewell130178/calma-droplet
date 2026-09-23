// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Calma",
    platforms: [.macOS(.v14)],
    products: [
        // A droplet is a loadable bundle, so its product is a dynamic library.
        // Do not make it static: the app already carries DroppyKit, and a
        // second copy inside the droplet gives the same type two metadata
        // records, which fails every cast between them.
        .library(name: "Calma", type: .dynamic, targets: ["Calma"])
    ],
    dependencies: [
        .package(url: "https://gitlab.com/droppyformac1/droppykit.git", .upToNextMinor(from: "1.8.1"))
    ],
    targets: [
        .target(
            name: "Calma",
            dependencies: [.product(name: "DroppyKit", package: "droppykit")]
        ),
        .executableTarget(
            name: "CalmaHarness",
            dependencies: [
                "Calma",
                .product(name: "DroppyKitHarness", package: "droppykit")
            ]
        )
    ]
)
