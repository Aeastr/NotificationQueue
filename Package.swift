// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NotificationQueue",
    platforms: [
        .iOS(.v16),
        .macCatalyst(.v16),
        .macOS(.v13),
        .watchOS(.v9),
        .tvOS(.v16),
        .visionOS(.v1)
    ],
    products: [.library(name: "NotificationQueue", targets: ["NotificationQueue"])],
    targets: [
        .target(name: "NotificationQueue"),
        .testTarget(name: "NotificationQueueTests", dependencies: ["NotificationQueue"])
    ]
)
