// swift-tools-version:5.9
// The Qanary SDK for iOS. No dependencies beyond the system frameworks.

import PackageDescription

let package = Package(
    name: "Qanary",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "Qanary", targets: ["Qanary"]),
    ],
    targets: [
        .target(
            name: "Qanary",
            path: "Sources/Qanary",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "QanaryTests",
            dependencies: ["Qanary"],
            path: "Tests/QanaryTests"
        ),
    ]
)
