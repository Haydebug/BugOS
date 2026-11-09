import AppKit
import ApplicationServices
import SwiftUI

/// Handoff: the app another device (an iPhone, an iPad) offers to continue on this Mac.
/// macOS shows it as an extra icon at the end of the Dock, which BugOS keeps hidden, so the taskbar shows it
/// instead. The Dock still has the item in its accessibility tree; read it from there and press it to continue.
/// Event-driven: the Dock announces the item appearing and disappearing (AXCreated / AXUIElementDestroyed).
@MainActor
final class Handoff: ObservableObject {
    static let shared = Handoff()

    struct Offer: Equatable {
        let title: String       // the app's name, e.g. "Safari"
        let device: String      // "iPhone" or "iPad", from the item's status label (e.g. "com.apple.iphone-17-2")
        let appURL: URL?        // the matching Mac app, for its icon
        static func == (a: Offer, b: Offer) -> Bool { a.title == b.title && a.device == b.device && a.appURL == b.appURL }
    }

    @Published private(set) var offer: Offer?
    private var element: AXUIElement?
    private var observer: AXObserver?
    private var dockPID: pid_t = 0
    private var pending = false

    private init() {
        attach()
        // The Dock restarts now and then (and whenever BugOS changes its settings): watch the new one.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
            let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            guard id == "com.apple.dock" else { return }
            MainActor.assumeIsolated { Handoff.shared.attach() }
        }
    }

    /// Start (or restart) watching the running Dock.
    func attach() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        guard AX.isTrusted,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { offer = nil; return }
        dockPID = dock.processIdentifier
        var obs: AXObserver?
        guard AXObserverCreate(dockPID, { _, _, _, _ in
            MainActor.assumeIsolated { Handoff.shared.readSoon() }
        }, &obs) == .success, let obs else { return }
        let app = AXUIElementCreateApplication(dockPID)
        AXObserverAddNotification(obs, app, kAXCreatedNotification as CFString, nil)
        AXObserverAddNotification(obs, app, kAXUIElementDestroyedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
        read()
    }

    /// The Dock adds and removes several elements at once: read once per burst.
    private func readSoon() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.pending = false
            self.read()
        }
    }

    private func read() {
        let app = AXUIElementCreateApplication(dockPID)
        let list = AX.elements(app, kAXChildrenAttribute).first { AX.string($0, kAXRoleAttribute) == "AXList" }
        let item = list.flatMap { AX.elements($0, kAXChildrenAttribute).first { AX.string($0, kAXSubroleAttribute) == "AXHandoffDockItem" } }
        element = item
        guard let item, let title = AX.string(item, kAXTitleAttribute), !title.isEmpty else {
            if offer != nil { offer = nil }
            return
        }
        let label = (AX.string(item, "AXStatusLabel") ?? "").lowercased()
        let device = label.contains("ipad") ? "iPad" : label.contains("watch") ? "Apple Watch" : label.contains("mac") ? "Mac" : "iPhone"
        let new = Offer(title: title, device: device, appURL: Self.appURL(item: item, title: title))
        if new != offer { offer = new }
    }

    /// Continue the activity on this Mac (what clicking the Dock's Handoff icon does).
    func open() {
        guard let element else { return }
        if AXUIElementPerformAction(element, kAXPressAction as CFString) != .success {
            read()   // it went away meanwhile
        }
    }

    /// The Mac app for the offer: the Dock item's own URL when it has one, otherwise the app with that name.
    private static func appURL(item: AXUIElement, title: String) -> URL? {
        if let v = AX.value(item, kAXURLAttribute), CFGetTypeID(v) == CFURLGetTypeID() {
            let url = v as! URL
            if url.pathExtension == "app" { return url }
        }
        for dir in ["/Applications", "/System/Applications", "/System/Cryptexes/App/System/Applications",
                    NSHomeDirectory() + "/Applications"] {
            let u = URL(fileURLWithPath: dir).appendingPathComponent(title + ".app")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    var icon: NSImage {
        if let url = offer?.appURL { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(systemSymbolName: "iphone", accessibilityDescription: nil) ?? NSImage()
    }
}

/// The taskbar's Handoff button: the app's icon with a small device badge. BugOS › Taskbar › Handoff puts it in
/// its own island in the bar's right corner, or after the app icons (behind a thin divider, like the Mac Dock).
struct HandoffButton: View {
    @ObservedObject var handoff = Handoff.shared
    var look: BarStyle
    var island: Bool
    @State private var hovering = false

    var body: some View {
        if let offer = handoff.offer {
            HStack(spacing: 4) {
                if !island {
                    Capsule().fill(Color.white.opacity(0.3)).frame(width: 1, height: Metrics.icon * 0.8).padding(.horizontal, 4)
                }
                Button { handoff.open() } label: {
                    ZStack(alignment: .bottomTrailing) {
                        Image(nsImage: handoff.icon)
                            .resizable().interpolation(.high)
                            .frame(width: Metrics.icon, height: Metrics.icon)
                            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        if look.handoffBadge {
                            Image(systemName: offer.device == "iPad" ? "ipad" : offer.device == "Mac" ? "laptopcomputer" : "iphone")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(2.5)
                                .background(Circle().fill(Color.black.opacity(0.7)))
                                .offset(x: 3, y: 2)
                        }
                    }
                    .frame(width: island ? Metrics.icon + 14 : look.height - 4, height: island ? Metrics.icon + 10 : look.height - 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(hovering ? 0.12 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .onHover { hovering = $0 }
                .help("\(offer.title) from \(offer.device)")
            }
            .padding(island ? 3 : 0)
            .background {
                if island && look.handoffGlass {
                    let shape = RoundedRectangle(cornerRadius: min(look.corner, 12) + 2, style: .continuous)
                    VisualEffect(material: .hudWindow).clipShape(shape)
                        .overlay(shape.strokeBorder(Color.white.opacity(0.12)))
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }
}
