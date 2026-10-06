// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CentillionSDK",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CentillionSDK", targets: ["CentillionSDK"])],
    targets: [
        .target(name: "CentillionSDK"),
        .testTarget(name: "CentillionSDKTests", dependencies: ["CentillionSDK"])
    ]
)
