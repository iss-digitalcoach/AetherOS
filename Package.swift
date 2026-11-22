// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AetherOS",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AetherOS",
            path: "Sources/AetherOS",
            linkerSettings: [
                // Embeds usage strings so microphone / speech / Finder prompts work for a bare executable.
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", "Info.plist"])
            ]
        )
    ]
)
