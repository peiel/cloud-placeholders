// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CloudPlaceholderClient",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "CloudPlaceholderDomain", targets: ["CloudPlaceholderDomain"]),
        .library(name: "CloudPlaceholderPersistence", targets: ["CloudPlaceholderPersistence"]),
        .library(name: "CloudPlaceholderSync", targets: ["CloudPlaceholderSync"]),
        .library(name: "CloudPlaceholderFileProviderKit", targets: ["CloudPlaceholderFileProviderKit"]),
        .executable(name: "cloudsync-demo", targets: ["cloudsync-demo"]),
    ],
    targets: [
        .target(
            name: "CloudPlaceholderDomain"
        ),
        .target(
            name: "CloudPlaceholderPersistence",
            dependencies: ["CloudPlaceholderDomain"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "CloudPlaceholderSync",
            dependencies: ["CloudPlaceholderDomain", "CloudPlaceholderPersistence"]
        ),
        .target(
            name: "CloudPlaceholderFileProviderKit",
            dependencies: ["CloudPlaceholderDomain", "CloudPlaceholderPersistence", "CloudPlaceholderSync"]
        ),
        .executableTarget(
            name: "cloudsync-demo",
            dependencies: ["CloudPlaceholderDomain", "CloudPlaceholderPersistence", "CloudPlaceholderSync"]
        ),
        .testTarget(
            name: "CloudPlaceholderPersistenceTests",
            dependencies: ["CloudPlaceholderPersistence"]
        ),
        .testTarget(
            name: "CloudPlaceholderSyncTests",
            dependencies: ["CloudPlaceholderSync", "CloudPlaceholderPersistence"]
        ),
    ]
)
