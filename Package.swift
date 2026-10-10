// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Screenshooter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Screenshooter", targets: ["Screenshooter"]),
        .executable(name: "shotprobe", targets: ["ShotProbe"]),
    ],
    targets: [
        // Localization and screen geometry shared by every module
        .target(
            name: "ShotCore",
            path: "Sources/ShotCore"
        ),
        // Content regions found in a screenshot by its pixels: panels, bubbles, cards, text blocks (no UI, no system state)
        .target(
            name: "ScreenSegmenter",
            path: "Sources/ScreenSegmenter"
        ),
        // Regions under the cursor: windows, accessibility elements, visual regions, and their nesting
        .target(
            name: "Detection",
            dependencies: ["ShotCore", "ScreenSegmenter"],
            path: "Sources/Detection"
        ),
        // Annotation editor window: arrows, shapes, text, blur, crop
        .target(
            name: "AnnotationEditor",
            dependencies: ["ShotCore"],
            path: "Sources/AnnotationEditor"
        ),
        // Pictures and the clipboard: background removal, moodboards, several pictures copied at once (no UI)
        .target(
            name: "PictureTools",
            path: "Sources/PictureTools"
        ),
        // The menu bar app with the capture overlay and the notch shelf
        .executableTarget(
            name: "Screenshooter",
            dependencies: ["ShotCore", "Detection", "AnnotationEditor", "PictureTools"],
            path: "Sources/Screenshooter"
        ),
        // Command line tool for checking region detection on the live screen without the UI
        .executableTarget(
            name: "ShotProbe",
            dependencies: ["Detection"],
            path: "Sources/ShotProbe"
        ),
        .testTarget(
            name: "ShotCoreTests",
            dependencies: ["ShotCore"],
            path: "Tests/ShotCoreTests"
        ),
        .testTarget(
            name: "ScreenSegmenterTests",
            dependencies: ["ScreenSegmenter"],
            path: "Tests/ScreenSegmenterTests"
        ),
        .testTarget(
            name: "DetectionTests",
            dependencies: ["Detection"],
            path: "Tests/DetectionTests"
        ),
        .testTarget(
            name: "PictureToolsTests",
            dependencies: ["PictureTools"],
            path: "Tests/PictureToolsTests"
        ),
    ]
)
