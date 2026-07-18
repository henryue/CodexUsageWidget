// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexUsageWidgetCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodexUsageCore", targets: ["CodexUsageCore"]),
        .executable(name: "CodexUsageSmoke", targets: ["CodexUsageSmoke"])
    ],
    targets: [
        .target(
            name: "CodexUsageCore",
            path: "Shared",
            exclude: ["ClarityWidgetView.swift"],
            sources: [
                "UsageModels.swift",
                "AppInteractionPolicies.swift",
                "RateLimitsParser.swift",
                "ResetTimeFormatter.swift",
                "SnapshotStore.swift"
            ]
        ),
        .testTarget(
            name: "CodexUsageCoreTests",
            dependencies: ["CodexUsageCore"],
            path: "Tests"
        ),
        .target(
            name: "CodexUsageRuntime",
            dependencies: ["CodexUsageCore"],
            path: "App",
            exclude: [
                "CodexUsageApp.swift",
                "DashboardView.swift",
                "UsageController.swift",
                "IconSource",
                "Info.plist",
                "CodexUsage.entitlements"
            ],
            sources: ["CodexAppServerClient.swift"]
        ),
        .testTarget(
            name: "CodexUsageRuntimeTests",
            dependencies: ["CodexUsageCore", "CodexUsageRuntime"],
            path: "RuntimeTests"
        ),
        .executableTarget(
            name: "CodexUsageSmoke",
            dependencies: ["CodexUsageCore", "CodexUsageRuntime"],
            path: "Smoke"
        )
    ]
)
