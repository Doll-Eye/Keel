// swift-tools-version: 5.9
// Keel: the shared foundation Muteny and Flotilla are both built on — the controller,
// speech, sound, haptics and the log. Named for the backbone of a hull; rename here and in
// the apps' imports if a better nautical word turns up.
import PackageDescription

let package = Package(
    name: "Keel",
    platforms: [.macOS("27.0")],   // matches the apps' deployment target; Sound uses 27-only AVAudioEngine API
    products: [
        .library(name: "Keel", targets: ["Keel"])
    ],
    targets: [
        .target(
            name: "Keel",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit")
            ])
    ]
)
