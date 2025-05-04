// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Netti",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
        .macCatalyst(.v13),
    ],
    products: [
        .library(name: "Netti", targets: ["Netti"])
    ],
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire", .upToNextMajor(from: "5.10.2")),
    ],
    targets: [
        .target(
            name: "Netti",
            dependencies: [
                .product(name: "Alamofire", package: "Alamofire"),
            ],
        ),
        .testTarget(
            name: "NettiTests",
            dependencies: ["Netti"]
        ),
    ]
)
