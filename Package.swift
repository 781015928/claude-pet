// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudePet",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClaudePet", targets: ["ClaudePet"])
    ],
    targets: [
        .executableTarget(
            name: "ClaudePet",
            path: "Sources/ClaudePet"
        )
    ]
)
