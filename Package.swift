// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "dyntile",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "dyntile",
            path: "Sources/dyntile",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
