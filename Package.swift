// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HoldTalk",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "HoldTalk",
            path: "Sources/HoldTalk"
        ),
        .testTarget(name: "HoldTalkTests", dependencies: ["HoldTalk"])
    ]
)
