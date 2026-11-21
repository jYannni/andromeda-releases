// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Andromeda",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AndromedaCore", targets: ["AndromedaCore"]),
        .executable(name: "andromeda-report", targets: ["andromeda-report"]),
        .library(name: "AndromedaHelperProtocol", targets: ["AndromedaHelperProtocol"]),
        .library(name: "AndromedaHelperCore", targets: ["AndromedaHelperCore"]),
        .library(name: "AndromedaHelperClient", targets: ["AndromedaHelperClient"]),
        .executable(name: "diskplain-helper", targets: ["diskplain-helper"]),
        .executable(name: "andromeda-helperctl", targets: ["andromeda-helperctl"]),
        .executable(name: "diskplain-automation-worker", targets: ["diskplain-automation-worker"]),
        .library(name: "AndromedaOrganize", targets: ["AndromedaOrganize"]),
        .library(name: "AndromedaAppModel", targets: ["AndromedaAppModel"]),
        .library(name: "AndromedaUI", targets: ["AndromedaUI"]),
        .executable(name: "Andromeda", targets: ["Andromeda"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(
            name: "AndromedaCore",
            resources: [.copy("Catalog/Entries")]
        ),
        .executableTarget(
            name: "andromeda-report",
            dependencies: ["AndromedaCore"]
        ),
        .plugin(
            name: "HelperBuildInfo",
            capability: .buildTool()
        ),
        .target(
            name: "AndromedaHelperProtocol",
            plugins: ["HelperBuildInfo"]
        ),
        .target(
            name: "AndromedaHelperCore",
            dependencies: ["AndromedaHelperProtocol"]
        ),
        .target(
            name: "AndromedaHelperClient",
            dependencies: ["AndromedaHelperProtocol", "AndromedaCore"]
        ),
        .executableTarget(
            name: "diskplain-helper",
            dependencies: ["AndromedaHelperProtocol", "AndromedaHelperCore"]
        ),
        .executableTarget(
            name: "andromeda-helperctl",
            dependencies: ["AndromedaHelperClient", "AndromedaHelperProtocol"]
        ),
        .target(
            name: "AndromedaOrganize",
            dependencies: ["AndromedaCore"]
        ),
        .target(
            name: "AndromedaAppModel",
            dependencies: [
                "AndromedaCore", "AndromedaOrganize", "AndromedaHelperClient", "AndromedaHelperProtocol",
            ],
            resources: [.copy("Releases.json")]
        ),
        .executableTarget(name: "diskplain-automation-worker", dependencies: ["AndromedaAppModel"]),
        .target(
            name: "AndromedaUI",
            dependencies: ["AndromedaAppModel", "AndromedaOrganize", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .executableTarget(
            name: "Andromeda",
            dependencies: ["AndromedaUI", "AndromedaAppModel", .product(name: "Sparkle", package: "Sparkle")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
