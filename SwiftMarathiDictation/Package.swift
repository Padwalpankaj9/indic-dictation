// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SwiftMarathiDictation",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MarathiDictationApp", targets: ["MarathiDictationApp"])
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
