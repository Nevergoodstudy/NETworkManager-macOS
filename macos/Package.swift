// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "NETworkManagerMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NETworkManagerMac", targets: ["NMApp"]),
        .executable(name: "NMCheck", targets: ["SelfTest"]),
        .executable(name: "NMTest", targets: ["TestRunner"]),
        .executable(name: "NMCP", targets: ["NMMCP"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.11.2"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .target(
            name: "NMCore",
            resources: [.copy("Resources")]
        ),
        .target(name: "NMMCPTools", dependencies: ["NMCore", .product(name: "MCP", package: "swift-sdk")]),
        .executableTarget(name: "NMMCP", dependencies: ["NMMCPTools", .product(name: "MCP", package: "swift-sdk")]),
        .target(name: "NMDashboard", dependencies: ["NMCore"]),
        .target(name: "NMNetworkInfo", dependencies: ["NMCore"]),
        .target(name: "NMScanners", dependencies: ["NMCore"]),
        .target(name: "NMLookups", dependencies: ["NMCore"]),
        .target(name: "NMCalculators", dependencies: ["NMCore"]),
        .target(name: "NMUtilities", dependencies: ["NMCore"]),
        .target(name: "NMRemote", dependencies: ["NMCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .target(name: "NMProfiles", dependencies: ["NMCore"]),
        .target(name: "NMAssets", dependencies: ["NMCore"]),
        .target(name: "NMIntegrations", dependencies: ["NMCore", "NMAssets"]),
        .target(name: "NMSettingsKit", dependencies: ["NMCore"]),
        .executableTarget(
            name: "NMApp",
            dependencies: [
                "NMCore", "NMDashboard", "NMNetworkInfo", "NMScanners", "NMLookups",
                "NMCalculators", "NMUtilities", "NMRemote", "NMProfiles", "NMAssets", "NMIntegrations", "NMSettingsKit"
            ]
        ),
        .executableTarget(
            name: "SelfTest",
            dependencies: ["NMCore", "NMScanners", "NMLookups", "NMCalculators"]
        ),
        .executableTarget(name: "TestRunner", dependencies: ["NMCore", "NMScanners", "NMCalculators", "NMAssets", "NMIntegrations", "NMRemote"])
    ],
    swiftLanguageModes: [.v5]
)
