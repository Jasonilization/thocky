// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "keystrike",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "keystrike", targets: ["keystrike"])
    ],
    targets: [
        // Native Core Audio engine (C). Pre-loaded RAM buffers + real-time mixer.
        .target(
            name: "ThockAudio",
            path: "Sources/ThockAudio",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        // IOKit HID bridge to the undocumented AppleSPU accelerometer (C).
        .target(
            name: "ThockSPU",
            path: "Sources/ThockSPU",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        // Swift menu-bar app.
        .executableTarget(
            name: "keystrike",
            dependencies: ["ThockAudio", "ThockSPU"],
            path: "Sources/keystrike"
        )
    ]
)
