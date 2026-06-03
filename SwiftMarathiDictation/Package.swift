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
    targets: [
        .executableTarget(
            name: "MarathiDictationApp",
            resources: [
                .copy("Resources/Icons")
            ]
        )
    ]
)
