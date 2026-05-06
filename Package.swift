// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudePet",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClaudePet", targets: ["ClaudePet"]),
        .executable(name: "ClaudePetIconGen", targets: ["ClaudePetIconGen"])
    ],
    targets: [
        .executableTarget(
            name: "ClaudePet",
            path: "Sources/ClaudePet"
        ),
        .executableTarget(
            name: "ClaudePetIconGen",
            path: "Sources/ClaudePetIconGen"
        )
    ]
)
