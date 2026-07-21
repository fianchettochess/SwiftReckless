// swift-tools-version: 6.0

import PackageDescription

guard let packageURL = Context.environment["SWIFTRECKLESS_TEST_URL"],
      !packageURL.isEmpty else {
    fatalError("SWIFTRECKLESS_TEST_URL must point to the ephemeral tagged repository")
}

let package = Package(
    name: "SwiftRecklessRemoteConsumer",
    platforms: [
        .macOS(.v10_15),
    ],
    dependencies: [
        .package(url: packageURL, exact: "999.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "SwiftRecklessRemoteConsumer",
            dependencies: [
                .product(name: "SwiftReckless", package: "SwiftReckless"),
            ]
        ),
    ]
)
