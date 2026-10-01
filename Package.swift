// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Neutrino",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "NeutrinoCore",
            path: "Sources/NeutrinoCore"
        ),
        .executableTarget(
            name: "Neutrino",
            dependencies: ["NeutrinoCore"],
            path: "Sources/Neutrino",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        ),
        .testTarget(
            name: "NeutrinoCoreTests",
            dependencies: ["NeutrinoCore"],
            path: "Tests/NeutrinoCoreTests"
        ),
    ]
)
