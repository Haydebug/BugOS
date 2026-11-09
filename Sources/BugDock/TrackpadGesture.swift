// Trackpad gesture for the quick corner: swipe two fingers in from the right edge of the trackpad (where
// Notification Center's swipe was; BugOS turns that one off). A glass column of the quick corner's shortcuts
// slides in from the right side of the screen (QuickPanel.swift) with the top one highlighted; slide down to
// move the highlight, lift to open it, swipe back out to the edge to close it.
//
// macOS has no API for new trackpad gestures, so this reads raw finger positions from Apple's private
// MultitouchSupport framework (as BetterTouchTool and Jitouch do; still working on macOS 27). It's
// loaded with dlopen: if a future macOS changes it, the gesture just doesn't start and nothing else
// is affected. While the gesture is under way, the scroll it would also cause is swallowed (an event
// tap, covered by BugOS's Accessibility permission).
import AppKit
import BugOSKit

@MainActor
final class TrackpadGesture {
    static let shared = TrackpadGesture()

    /// BugOS › Quick Corner › Trackpad gesture (on by default).
    static var enabled: Bool { UserDefaults.standard.object(forKey: QuickCornerCatalog.gestureKey) as? Bool ?? true }


    weak var corner: QuickCornerController?
    private var devices: [UnsafeMutableRawPointer] = []
    /// The device list has to stay alive: if it's released, the devices go with it and touches stop arriving.
    private var deviceList: CFArray?
    private var tap: CFMachPort?
    private var running = false

    // MARK: The private framework

    private typealias Callback = @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Void

    private struct API {
        let createList: CreateList, register: Register, unregister: Register, start: Start, stop: Stop
    }
    private static let api: API? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY),
              let a = dlsym(h, "MTDeviceCreateList"), let b = dlsym(h, "MTRegisterContactFrameCallback"),
              let c = dlsym(h, "MTUnregisterContactFrameCallback"), let d = dlsym(h, "MTDeviceStart"),
              let e = dlsym(h, "MTDeviceStop") else { return nil }
        return API(createList: unsafeBitCast(a, to: CreateList.self), register: unsafeBitCast(b, to: Register.self),
                   unregister: unsafeBitCast(c, to: Register.self), start: unsafeBitCast(d, to: Start.self),
                   stop: unsafeBitCast(e, to: Stop.self))
    }()

    nonisolated static func log(_ s: String) {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Bug OS.log")
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        h.seekToEndOfFile(); h.write(Data("\(Date()) Taskbar \(s)\n".utf8)); try? h.close()
    }

    // MARK: On / off

    /// Start or stop listening to follow the setting (and whether the quick corner itself is on).
    func reload() {
        let want = Self.enabled   // Quick Access is on its own: the quick corner can be off
        if want && !running { start() } else if !want && running { stop() }
    }

    private func start() {
        guard let api = Self.api, let cfList = api.createList()?.takeRetainedValue(), let list = cfList as? [AnyObject] else {
            Self.log("trackpad gesture unavailable: MultitouchSupport not found")
            return
        }
        deviceList = cfList
        devices = list.map { Unmanaged.passUnretained($0).toOpaque() }
        for d in devices {
            api.register(d, touchCallback)
            api.start(d, 0)
        }
        installScrollTap()
        running = true
        Self.log("trackpad gesture on: \(devices.count) touch device(s), scroll tap \(tap == nil ? "missing" : "ok")")
    }

    private func stop() {
        if let api = Self.api {
            for d in devices { api.unregister(d, touchCallback); api.stop(d) }
        }
        devices = []
        deviceList = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        running = false
    }

    // MARK: Swallowing the scroll

    private func installScrollTap() {
        guard tap == nil else { CGEvent.tapEnable(tap: tap!, enable: true); return }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                DispatchQueue.main.async { MainActor.assumeIsolated { TrackpadGesture.shared.reenableTap() } }
                return Unmanaged.passUnretained(event)
            }
            return GestureState.swallowScroll ? nil : Unmanaged.passUnretained(event)
        }, userInfo: nil)
        guard let tap else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func reenableTap() { if let tap, running { CGEvent.tapEnable(tap: tap, enable: true) } }

    // MARK: Gesture (main thread)

    fileprivate func fired() {
        guard let corner, !corner.side.isOpen, !corner.isHiddenForFullScreen else { return }
        corner.close()        // the fan, if the mouse had it open
        corner.side.open()
    }

    fileprivate func climbed(to progress: Double) {
        guard let corner, corner.side.isOpen, progress >= 0 else { return }
        corner.side.highlight(fraction: progress)
    }

    fileprivate func swipedOut() { corner?.side.close() }

    fileprivate func lifted() { corner?.side.runHighlighted() }
}

/// Touch tracking, on MultitouchSupport's own thread. Only plain values cross to the main thread.
private enum GestureState {
    nonisolated(unsafe) static var swallowScroll = false
    nonisolated(unsafe) static var candidate = false     // two fingers landed on the right edge
    nonisolated(unsafe) static var fired = false
    nonisolated(unsafe) static var startX = 0.0, startY = 0.0
    nonisolated(unsafe) static var fireX = 0.0, fireY = 0.0
    nonisolated(unsafe) static var releaseAt = 0.0       // keep swallowing momentum scroll a moment after lifting
    nonisolated(unsafe) static var lastCount = 0
}

/// One frame of touches. Each finger record is 96 bytes; normalized position (0…1, origin bottom-left)
/// is at bytes 32 (x) and 36 (y).
///
/// The gesture: two fingers land on the right edge of the pad and swipe in (left), like Notification
/// Center's swipe (which BugOS turns off). The fan opens with its top shortcut highlighted; sliding down
/// moves the highlight down the fan, lifting opens it, swiping back out toward the edge closes it.
private let touchCallback: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32 = { _, data, count, time, _ in
    let n = Int(count)
    GestureState.lastCount = n
    if n == 0 {
        if GestureState.candidate || GestureState.fired { GestureState.releaseAt = time + 0.6 }
        // Lifting after the fan opened: open the highlighted shortcut.
        if GestureState.fired { DispatchQueue.main.async { MainActor.assumeIsolated { TrackpadGesture.shared.lifted() } } }
        GestureState.candidate = false
        GestureState.fired = false
    }
    if GestureState.swallowScroll, !GestureState.candidate, !GestureState.fired, time > GestureState.releaseAt {
        GestureState.swallowScroll = false
    }
    guard n == 2, let data else {
        if n > 2 { GestureState.candidate = false }     // more fingers: someone else's gesture
        return 0
    }
    let f0 = data, f1 = data + 96
    let xs = [Double(f0.load(fromByteOffset: 32, as: Float.self)), Double(f1.load(fromByteOffset: 32, as: Float.self))]
    let ys = [Double(f0.load(fromByteOffset: 36, as: Float.self)), Double(f1.load(fromByteOffset: 36, as: Float.self))]
    let x = (xs[0] + xs[1]) / 2, y = (ys[0] + ys[1]) / 2

    if !GestureState.candidate && !GestureState.fired {
        // Both fingers start on the right edge.
        if xs.allSatisfy({ $0 > 0.88 }) {
            GestureState.candidate = true
            GestureState.startX = x
            GestureState.startY = y
            GestureState.swallowScroll = true
        }
        return 0
    }
    if GestureState.candidate && !GestureState.fired {
        let dx = GestureState.startX - x, dy = abs(y - GestureState.startY)
        if dy > 0.12 && dy > dx { GestureState.candidate = false; return 0 }   // a vertical scroll, not ours
        if dx > 0.09 {
            GestureState.fired = true
            GestureState.candidate = false
            GestureState.fireX = x
            GestureState.fireY = y
            DispatchQueue.main.async { MainActor.assumeIsolated { TrackpadGesture.log("gesture: fired"); TrackpadGesture.shared.fired() } }
        }
        return 0
    }
    if GestureState.fired {
        // Swiped back out toward the edge: close the fan (and stop following these fingers).
        if x > GestureState.fireX + 0.06 {
            GestureState.fired = false
            GestureState.releaseAt = time + 0.6
            DispatchQueue.main.async { MainActor.assumeIsolated { TrackpadGesture.shared.swipedOut() } }
            return 0
        }
        // Down from where it fired: 0 = top of the fan … 1 = the bottom, about half the pad's height.
        let down = max(0, min(1, (GestureState.fireY - y) / 0.45))
        DispatchQueue.main.async { MainActor.assumeIsolated { TrackpadGesture.shared.climbed(to: down) } }
    }
    return 0
}
