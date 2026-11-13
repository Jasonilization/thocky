// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "thocky",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "thocky", targets: ["thocky"])
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
            name: "thocky",
            dependencies: ["ThockAudio", "ThockSPU"],
            path: "Sources/Thocky"
        )
    ]
)
