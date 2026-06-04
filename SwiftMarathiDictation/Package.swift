// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SwiftIndicDictation",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "IndicDictationApp", targets: ["MarathiDictationApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/livekit/livekit-wakeword", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "MarathiDictationApp",
            dependencies: [
                .product(name: "LiveKitWakeWord", package: "livekit-wakeword")
            ],
            resources: [
                .copy("Resources/Icons"),
                .copy("Resources/WakeWord")
            ]
        )
    ]
)
