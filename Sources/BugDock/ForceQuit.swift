// Force quit, for apps and pop-ups that won't go away.
// - Right-click an app on the taskbar › "Force quit" kills it straight away (no "save changes?" asking).
// - Hover any window or pop-up (even ones that aren't on the taskbar) and press ⌃⌥⌘Q: the app that owns the
//   window under the pointer is killed.
import AppKit
import Carbon.HIToolbox

@MainActor
enum ForceQuit {
    /// Kill these processes now. forceTerminate is SIGKILL for apps; plain kill() catches helper processes
    /// that NSRunningApplication doesn't know about.
    static func kill(_ pids: [pid_t]) {
        for pid in pids where pid != getpid() && pid > 1 {
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
            let ok = NSRunningApplication(processIdentifier: pid)?.forceTerminate() ?? false
            if !ok { _ = Darwin.kill(pid, SIGKILL) }
            WindowTracker.log("force quit: \(name) (\(pid)) \(ok ? "forceTerminate" : "SIGKILL")")
        }
    }

    // MARK: ⌃⌥⌘Q: the window under the pointer

    private static var ref: EventHotKeyRef?
    private static let signature = OSType(0x4246_5155)   // "BFQU"
    /// Never killed from the hotkey: hovering the desktop, the menu bar or the Dock shouldn't log you out.
    private static let protected: Set<String> = ["Window Server", "WindowServer", "Dock", "loginwindow",
                                                 "SystemUIServer", "Control Center", "ControlCenter"]

    static func install() {
        guard ref == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard hk.signature == OSType(0x4246_5155) else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { MainActor.assumeIsolated { ForceQuit.underPointer() } }
            return noErr
        }, 1, &spec, nil, nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_Q), UInt32(controlKey | optionKey | cmdKey),
                            EventHotKeyID(signature: signature, id: 1), GetApplicationEventTarget(), 0, &ref)
    }

    static func underPointer() {
        guard let pid = pidUnderPointer() else { WindowTracker.log("force quit: nothing under the pointer"); return }
        kill([pid])
    }

    /// Topmost visible window under the mouse (any layer, so pop-ups and panels count), skipping our own bar
    /// and the system's own processes.
    private static func pidUnderPointer() -> pid_t? {
        let mouse = CGEvent(source: nil)?.location ?? .zero   // global, top-left origin like CGWindow bounds
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for w in list {   // front to back
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                  let layer = w[kCGWindowLayer as String] as? Int, layer >= 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b), rect.width > 4, rect.height > 4,
                  rect.contains(mouse) else { continue }
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            if protected.contains(owner) { return nil }   // the menu bar / Dock is on top here: do nothing
            return pid
        }
        return nil
    }
}
