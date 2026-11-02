// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Netti",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .watchOS(.v10),
        .macCatalyst(.v17),
    ],
    products: [
        .library(name: "Netti", targets: ["Netti"]),
        .library(name: "NettiTesting", targets: ["NettiTesting"]),
    ],
    targets: [
        .target(name: "Netti"),
        .target(
            name: "NettiTesting",
            dependencies: ["Netti"]
        ),
        .executableTarget(
            name: "NettiExamples",
            dependencies: ["Netti", "NettiTesting"],
            path: "Examples"
        ),
        .testTarget(
            name: "NettiTests",
            dependencies: ["Netti", "NettiTesting"],
            resources: [.copy("Resources")]
        ),
    ]
)
