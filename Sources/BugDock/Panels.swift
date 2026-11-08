import AppKit
import SwiftUI

/// Borderless panel that never steals focus from the app you're using.
class FloatingPanel: NSPanel {
    init(level: NSWindow.Level) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 48),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true   // must come before `level`: setting it resets the level to .floating
        self.level = level
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Same, but can take keyboard focus (Start menu search box).
final class KeyablePanel: FloatingPanel {
    override var canBecomeKey: Bool { true }
}

/// Hosting view that reacts to the first click even though our app is never "active".
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

extension NSWindow.Level {
    static let taskbar = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
    static let taskbarPopup = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
    /// Aero Peek overlay: above every app window, just under the taskbar and its popup.
    static let peek = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
}
