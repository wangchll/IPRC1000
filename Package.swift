// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IPRC1000Adapter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "IPRC1000Adapter", targets: ["IPRC1000Adapter"])
    ],
    targets: [
        .target(
            name: "CRemoteSupport",
            linkerSettings: [
                .unsafeFlags(["-LVendor/lib"]),
                .linkedLibrary("sbc")
            ]
        ),
        .executableTarget(
            name: "IPRC1000Adapter",
            dependencies: ["CRemoteSupport"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("CoreAudio")
            ]
        )
    ]
)
