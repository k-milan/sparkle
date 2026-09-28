// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sparkle",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Sparkle", targets: ["Sparkle"])],
    targets: [
        .executableTarget(
            name: "Sparkle",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("UserNotifications"),
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
