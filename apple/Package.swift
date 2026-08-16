// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Odyssey",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .watchOS(.v11),
    ],
    products: [
        .library(name: "OdysseyDomain", targets: ["OdysseyDomain"]),
        .library(name: "OdysseyData", targets: ["OdysseyData"]),
        .library(name: "OdysseySync", targets: ["OdysseySync"]),
        .library(name: "OdysseyAuth", targets: ["OdysseyAuth"]),
        .library(name: "OdysseyApplication", targets: ["OdysseyApplication"]),
        .library(name: "OdysseyExtensionBridge", targets: ["OdysseyExtensionBridge"]),
        .library(
            name: "OdysseyWatchConnectivity",
            targets: ["OdysseyWatchConnectivity"]
        ),
        .library(name: "OdysseyHealth", targets: ["OdysseyHealth"]),
        .library(name: "OdysseyCalendar", targets: ["OdysseyCalendar"]),
        .library(name: "OdysseyWeather", targets: ["OdysseyWeather"]),
        .library(name: "OdysseyLocation", targets: ["OdysseyLocation"]),
        .library(name: "OdysseyIntegrations", targets: ["OdysseyIntegrations"]),
        .library(name: "OdysseyIntelligence", targets: ["OdysseyIntelligence"]),
        .library(name: "OdysseyDesignSystem", targets: ["OdysseyDesignSystem"]),
        .library(name: "OdysseyTelemetry", targets: ["OdysseyTelemetry"]),
        .library(name: "OdysseyTesting", targets: ["OdysseyTesting"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            exact: "7.11.1"
        ),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Packages/CSQLite",
            pkgConfig: "sqlite3",
            providers: [
                .apt(["libsqlite3-dev"]),
                .brew(["sqlite3"]),
            ]
        ),
        .target(
            name: "OdysseyDomain",
            path: "Packages/OdysseyDomain/Sources/OdysseyDomain"
        ),
        .target(
            name: "OdysseyData",
            dependencies: [
                "OdysseyDomain",
                "OdysseyIntegrations",
                "CSQLite",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Packages/OdysseyData/Sources/OdysseyData"
        ),
        .target(
            name: "OdysseySync",
            dependencies: ["OdysseyDomain", "OdysseyData"],
            path: "Packages/OdysseySync/Sources/OdysseySync"
        ),
        .target(
            name: "OdysseyAuth",
            dependencies: ["OdysseyDomain", "OdysseyData", "OdysseySync"],
            path: "Packages/OdysseyAuth/Sources/OdysseyAuth"
        ),
        .target(
            name: "OdysseyApplication",
            dependencies: [
                "OdysseyAuth",
                "OdysseyCalendar",
                "OdysseyDomain",
                "OdysseyData",
                "OdysseyExtensionBridge",
                "OdysseyHealth",
                "OdysseySync",
                "OdysseyWeather",
            ],
            path: "Packages/OdysseyApplication/Sources/OdysseyApplication"
        ),
        .target(
            name: "OdysseyExtensionBridge",
            dependencies: ["OdysseyDomain"],
            path: "Packages/OdysseyExtensionBridge/Sources/OdysseyExtensionBridge"
        ),
        .target(
            name: "OdysseyWatchConnectivity",
            dependencies: ["OdysseyDomain", "OdysseyExtensionBridge"],
            path: "Packages/OdysseyWatchConnectivity/Sources/OdysseyWatchConnectivity"
        ),
        .target(
            name: "OdysseyHealth",
            dependencies: ["OdysseyDomain", "OdysseyIntegrations"],
            path: "Packages/OdysseyHealth/Sources/OdysseyHealth"
        ),
        .target(
            name: "OdysseyCalendar",
            dependencies: ["OdysseyDomain", "OdysseyIntegrations"],
            path: "Packages/OdysseyCalendar/Sources/OdysseyCalendar"
        ),
        .target(
            name: "OdysseyLocation",
            dependencies: ["OdysseyDomain"],
            path: "Packages/OdysseyLocation/Sources/OdysseyLocation"
        ),
        .target(
            name: "OdysseyWeather",
            dependencies: ["OdysseyDomain", "OdysseyIntegrations"],
            path: "Packages/OdysseyWeather/Sources/OdysseyWeather"
        ),
        .target(
            name: "OdysseyIntegrations",
            path: "Packages/OdysseyIntegrations/Sources/OdysseyIntegrations"
        ),
        .target(
            name: "OdysseyIntelligence",
            dependencies: ["OdysseyDomain"],
            path: "Packages/OdysseyIntelligence/Sources/OdysseyIntelligence"
        ),
        .target(
            name: "OdysseyDesignSystem",
            dependencies: ["OdysseyDomain"],
            path: "Packages/OdysseyDesignSystem/Sources/OdysseyDesignSystem"
        ),
        .target(
            name: "OdysseyTelemetry",
            dependencies: ["OdysseyDomain"],
            path: "Packages/OdysseyTelemetry/Sources/OdysseyTelemetry"
        ),
        .target(
            name: "OdysseyTesting",
            dependencies: ["OdysseyDomain", "OdysseyData", "OdysseySync"],
            path: "Packages/OdysseyTesting/Sources/OdysseyTesting"
        ),
        .testTarget(
            name: "OdysseyDomainTests",
            dependencies: ["OdysseyDomain"],
            path: "Tests/Unit/OdysseyDomainTests"
        ),
        .testTarget(
            name: "OdysseyDataTests",
            dependencies: [
                "OdysseyData",
                "OdysseyDomain",
                "OdysseyIntegrations",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/Unit/OdysseyDataTests"
        ),
        .testTarget(
            name: "OdysseySyncTests",
            dependencies: ["OdysseySync", "OdysseyData", "OdysseyDomain"],
            path: "Tests/Unit/OdysseySyncTests"
        ),
        .testTarget(
            name: "OdysseyAuthTests",
            dependencies: ["OdysseyAuth", "OdysseyDomain", "OdysseySync"],
            path: "Tests/Unit/OdysseyAuthTests"
        ),
        .testTarget(
            name: "OdysseyApplicationTests",
            dependencies: [
                "OdysseyApplication",
                "OdysseyCalendar",
                "OdysseyData",
                "OdysseyDomain",
                "OdysseyExtensionBridge",
                "OdysseyHealth",
                "OdysseyIntegrations",
                "OdysseySync",
                "OdysseyWeather",
            ],
            path: "Tests/Unit/OdysseyApplicationTests"
        ),
        .testTarget(
            name: "OdysseyHealthTests",
            dependencies: ["OdysseyHealth", "OdysseyDomain", "OdysseyIntegrations"],
            path: "Tests/Unit/OdysseyHealthTests"
        ),
        .testTarget(
            name: "OdysseyCalendarTests",
            dependencies: ["OdysseyCalendar", "OdysseyDomain", "OdysseyIntegrations"],
            path: "Tests/Unit/OdysseyCalendarTests"
        ),
        .testTarget(
            name: "OdysseyWeatherTests",
            dependencies: ["OdysseyWeather", "OdysseyDomain", "OdysseyIntegrations"],
            path: "Tests/Unit/OdysseyWeatherTests"
        ),
        .testTarget(
            name: "OdysseyIntegrationsTests",
            dependencies: ["OdysseyIntegrations"],
            path: "Tests/Unit/OdysseyIntegrationsTests"
        ),
        .testTarget(
            name: "OdysseyTelemetryTests",
            dependencies: ["OdysseyTelemetry"],
            path: "Tests/Unit/OdysseyTelemetryTests"
        ),
        .testTarget(
            name: "OdysseyExtensionBridgeTests",
            dependencies: ["OdysseyExtensionBridge", "OdysseyDomain"],
            path: "Tests/Unit/OdysseyExtensionBridgeTests"
        ),
    ]
)
