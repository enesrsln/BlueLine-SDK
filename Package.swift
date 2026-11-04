// swift-tools-version: 5.9
// Swift Package Manager needs the manifest at the repository root to add the
// package by Git URL; the iOS sources live in ios/.
import PackageDescription

let package = Package(
    name: "BlueLineSDK",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "BlueLineSDK", targets: ["BlueLineSDK"])
    ],
    targets: [
        .target(name: "BlueLineSDK", path: "ios/Sources/BlueLineSDK"),
        .testTarget(name: "BlueLineSDKTests", dependencies: ["BlueLineSDK"], path: "ios/Tests/BlueLineSDKTests")
    ]
)
