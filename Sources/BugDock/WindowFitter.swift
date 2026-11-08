import AppKit
import ApplicationServices

/// Keeps windows out from under the taskbar, like Windows' "work area": when a window is
/// resized (zoom button, fill, drag) or created so its bottom goes below the bar's top edge,
/// BugDock trims it to end exactly at the bar. Pure moves are left alone, so you can still
/// drag a window partly under the bar on purpose. Public Accessibility API only.
@MainActor
final class WindowFitter {
    static let defaultsKey = "fitWindowsAboveBar"

    var isEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool) ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.defaultsKey)
            if newValue { fitAllWindows() }
        }
    }

    private var observers: [pid_t: AXObserver] = [:]
    private var pending: [Int: DispatchWorkItem] = [:]
    /// What we last set each window to, and when. An event whose frame matches is our own echo;
    /// anything else within `followWindow` is the system still animating (Fill, Zoom), so we follow it.
    private var lastSet: [Int: (frame: CGRect, at: Date)] = [:]
    private let followWindow: TimeInterval = 2.0
    private var followUps: [Int: Int] = [:]              // capped so a stubborn app can't loop us
    private var gaveUp: [Int: CGRect] = [:]              // app refused; retry only once the frame changes

    /// Called by WindowTracker with the current regular-app pids (only when AX is trusted).
    func sync(_ pids: [pid_t]) {
        let live = Set(pids)
        for (pid, obs) in observers where !live.contains(pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
            observers[pid] = nil
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for pid in pids where observers[pid] == nil && pid != getpid() {
            var obs: AXObserver?
            guard AXObserverCreate(pid, fitterCallback, &obs) == .success, let obs else { continue }
            let appEl = AX.app(pid)
            // Not ready yet (just launched)? The next sync tries again.
            guard AXObserverAddNotification(obs, appEl, kAXWindowResizedNotification as CFString, refcon) == .success else { continue }
            AXObserverAddNotification(obs, appEl, kAXWindowCreatedNotification as CFString, refcon)
            AXObserverAddNotification(obs, appEl, kAXWindowMovedNotification as CFString, refcon)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
            observers[pid] = obs
            // First time we see this app (including at BugDock launch): one pass over its windows.
            for w in AX.elements(appEl, kAXWindowsAttribute) { schedule(w, pid: pid, delay: 0.1) }
        }
    }

    func fitAllWindows() {
        for pid in observers.keys {
            for w in AX.elements(AX.app(pid), kAXWindowsAttribute) { schedule(w, pid: pid, delay: 0.05) }
        }
    }

    fileprivate func windowChanged(_ el: AXUIElement, moved: Bool) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success, pid != getpid() else { return }
        let key = Int(bitPattern: CFHash(el))
        let recent = lastSet[key].map { Date().timeIntervalSince($0.at) < followWindow } ?? false
        if recent, let f = AX.frame(el), let set = lastSet[key]?.frame, Self.same(f, set) { return }  // our own echo
        // A plain move is left alone (dragging a window partly under the bar is allowed),
        // unless we just trimmed this window and the system is still finishing its animation.
        if moved && !recent { return }
        schedule(el, pid: pid, delay: 0.35)
    }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    /// Debounced per window, so a live drag-resize isn't fought.
    private func schedule(_ el: AXUIElement, pid: pid_t, delay: TimeInterval) {
        let key = Int(bitPattern: CFHash(el))
        pending[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pending[key] = nil
            self?.fit(el, key: key)
        }
        pending[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fit(_ w: AXUIElement, key: Int) {
        guard isEnabled, AX.isTrusted,
              AX.string(w, kAXRoleAttribute) == kAXWindowRole,
              AX.string(w, kAXSubroleAttribute) == kAXStandardWindowSubrole,
              AX.bool(w, kAXMinimizedAttribute) != true,
              AX.bool(w, "AXFullScreen") != true,
              let frame = AX.frame(w),
              let primary = NSScreen.screens.first else { return }

        if let failed = gaveUp[key] {
            if failed == frame { return }
            gaveUp[key] = nil
        }

        // AX uses global top-left coordinates with the origin at the primary (menu-bar) screen's top-left.
        let screenH = primary.frame.height
        let barTop = screenH - Metrics.barHeight
        let visibleTop = screenH - primary.visibleFrame.maxY            // just under the menu bar
        let onBarScreen = frame.midX >= primary.frame.minX && frame.midX <= primary.frame.maxX
            && frame.minY < barTop
        guard onBarScreen else { return }

        // Just trimmed by us and then moved by a still-running animation (e.g. Fill moving its top
        // from 65 to 33 after we'd set the height): snap the bottom back onto the bar, gap or overlap.
        let followingUp = lastSet[key].map { Date().timeIntervalSince($0.at) < followWindow } ?? false
        if followingUp {
            guard abs(frame.maxY - barTop) > 1 else { return }
            followUps[key, default: 0] += 1
            guard followUps[key]! <= 3 else { return }
        } else {
            followUps[key] = 0
            guard frame.maxY > barTop + 2 else { return }               // 1–2pt is rounding
        }

        var origin = frame.origin
        var size = frame.size
        let available = barTop - visibleTop
        if frame.height > available || frame.minY < visibleTop {
            origin.y = visibleTop
            size.height = available
        } else {
            size.height = barTop - frame.minY
        }
        guard size.height >= 100 else { return }                        // don't crush a window parked low

        lastSet[key] = (CGRect(origin: origin, size: size), Date())
        var ok = true
        if origin != frame.origin, let v = AXValueCreate(.cgPoint, &origin) {
            ok = AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) == .success && ok
        }
        if let v = AXValueCreate(.cgSize, &size) {
            ok = AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) == .success && ok
        }
        // Refused (non-resizable): stop until the user changes the window again. Apps that clamp to a
        // minimum height are covered by the 3-follow-up cap above.
        if !ok {
            gaveUp[key] = AX.frame(w) ?? frame
            lastSet[key] = nil
            return
        }
        // Re-check once the system has finished whatever animation it was running.
        var pid: pid_t = 0
        if AXUIElementGetPid(w, &pid) == .success { schedule(w, pid: pid, delay: 0.7) }
        if lastSet.count > 500 { lastSet.removeAll(); gaveUp.removeAll(); followUps.removeAll() }
    }
}

private let fitterCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let fitter = Unmanaged<WindowFitter>.fromOpaque(refcon).takeUnretainedValue()
    let moved = (notification as String) == kAXWindowMovedNotification
    MainActor.assumeIsolated { fitter.windowChanged(element, moved: moved) }
}
