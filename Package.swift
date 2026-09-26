// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NotificationQueue",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "NotificationQueue", targets: ["NotificationQueue"])],
    targets: [
        .target(name: "NotificationQueue"),
        .testTarget(name: "NotificationQueueTests", dependencies: ["NotificationQueue"])
    ]
)
