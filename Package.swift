// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GoProUsbTransferTestApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "GoProUsbTransferTestApp",
            targets: ["GoProUsbTransferTestApp"]
        ),
        .executable(
            name: "CameraTransferAutoLauncher",
            targets: ["CameraTransferAutoLauncher"]
        )
    ],
    targets: [
        .executableTarget(
            name: "GoProUsbTransferTestApp"
        ),
        .executableTarget(
            name: "CameraTransferAutoLauncher"
        )
    ]
)
