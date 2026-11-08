// swift-tools-version:6.0
// Bug OS: a Windows 11-style layer for macOS. One app (Bug OS.app) that runs three parts as its own
// child processes, so every macOS permission belongs to "Bug OS". Build with ./build.sh.
import PackageDescription

let package = Package(
    name: "BugOS",
    platforms: [.macOS(.v15)],
    targets: [
        // Shared ids and the "hand yourself to Bug OS" helper.
        .target(name: "BugOSKit"),
        // Bug OS itself: starts and looks after the parts, the Bug OS page, first-run setup, uninstall.
        .executableTarget(name: "BugOS", dependencies: ["BugOSKit"]),
        // The Windows 11-style taskbar.
        .executableTarget(name: "BugDock", dependencies: ["BugOSKit"]),
        // The Windows 11-style file explorer (shown as "File Explorer").
        .executableTarget(name: "BugExplorer", dependencies: ["BugOSKit"]),
        // Screenshots and screen recordings.
        .executableTarget(name: "Squiggle", dependencies: ["BugOSKit"]),
    ],
    swiftLanguageModes: [.v5]
)
