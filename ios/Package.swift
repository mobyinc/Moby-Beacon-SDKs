// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MobyBeacon",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "MobyBeacon", targets: ["MobyBeacon"]),
    ],
    targets: [
        .target(name: "MobyBeacon"),
        .testTarget(name: "MobyBeaconTests", dependencies: ["MobyBeacon"]),
    ]
)
