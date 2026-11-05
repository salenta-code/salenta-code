// swift-tools-version: 5.9
// Salenta Code — ein Cockpit für deine KI-Agents, Aufgaben, Termine und Web-Apps auf dem Mac.
// Swift-Package; build.sh baut daraus ein echtes .app-Bundle.
import PackageDescription

let package = Package(
    name: "SalentaOS",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Native Terminal-Emulation für Claude Code, Codex und Junie.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.5.1"),
    ],
    targets: [
        // Reine Logik ohne UI (Aufgaben-Modell, Quick-Capture-Parser).
        .target(name: "AgenticOSKit"),
        .executableTarget(
            name: "SalentaOS",
            dependencies: [
                "AgenticOSKit",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        // Mac-Widgets (WidgetKit-Erweiterung) – build.sh packt sie als .appex in die App.
        .executableTarget(
            name: "SalentaWidgets",
            linkerSettings: [.linkedFramework("WidgetKit")]
        ),
        .testTarget(name: "AgenticOSKitTests", dependencies: ["AgenticOSKit"]),
    ]
)
