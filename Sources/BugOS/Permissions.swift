// The macOS permissions BugOS needs, why, and whether each is on. macOS files every part's request
// under "BugOS" (they run as its child processes), so BugOS can check them for all three parts.
import AppKit
import AVFoundation

enum Perm: String, CaseIterable, Identifiable {
    case accessibility, screen, fullDisk, microphone
    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screen: "Screen & System Audio Recording"
        case .fullDisk: "Full Disk Access"
        case .microphone: "Microphone"
        }
    }
    var symbol: String {
        switch self {
        case .accessibility: "accessibility"
        case .screen: "rectangle.dashed.badge.record"
        case .fullDisk: "internaldrive"
        case .microphone: "mic"
        }
    }
    var why: String {
        switch self {
        case .accessibility: "Lets the taskbar see, focus, minimise and snap your windows, and lets File Explorer take over Save and Open dialogs."
        case .screen: "Live window previews when you hover the taskbar, and Squiggle's screenshots and screen recordings."
        case .fullDisk: "Lets File Explorer show what's in the Recycle Bin (macOS locks the Trash folder). Everything else works without it."
        case .microphone: "Only for Squiggle recordings with the mic turned on."
        }
    }
    var optional: Bool { self == .microphone || self == .fullDisk }

    var settingsURL: URL {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        switch self {
        case .accessibility: return URL(string: base + "Privacy_Accessibility")!
        case .screen: return URL(string: base + "Privacy_ScreenCapture")!
        case .fullDisk: return URL(string: base + "Privacy_AllFiles")!
        case .microphone: return URL(string: base + "Privacy_Microphone")!
        }
    }
}

enum Permissions {
    static func isOn(_ p: Perm) -> Bool {
        switch p {
        case .accessibility: return AXIsProcessTrusted()
        case .screen: return CGPreflightScreenCaptureAccess()
        case .fullDisk:
            // The TCC database is only readable with Full Disk Access.
            let fd = open(NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
            if fd >= 0 { close(fd); return true }
            return false
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    /// A permission BugOS can't do its main job without is off.
    static var missingRequired: Bool { Perm.allCases.contains { !$0.optional && !isOn($0) } }

    /// Ask macOS for it (so BugOS shows up in the list), then open the right page of System Settings.
    static func request(_ p: Perm) {
        switch p {
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        case .screen:
            _ = CGRequestScreenCaptureAccess()
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
                return
            }
        case .fullDisk: break
        }
        NSWorkspace.shared.open(p.settingsURL)
    }
}
