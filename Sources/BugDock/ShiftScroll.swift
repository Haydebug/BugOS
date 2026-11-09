// Shift + scroll (BugOS › Misc):
//   default   the Mac's own behaviour (a mouse wheel scrolls sideways with Shift held);
//   sideways  always sideways with Shift, mouse wheel or trackpad;
//   vertical  never sideways: up/down stays up/down with Shift held (games where Shift is sprint and the
//             wheel zooms, like Roblox).
// CoreGraphics shows a scroll as sideways while Shift is on the event, so both modes start by taking Shift
// off the scroll event (the app still knows Shift is down from the keyboard).
import AppKit
import BugOSKit

@MainActor
final class ShiftScroll {
    static let shared = ShiftScroll()
    private var tap: CFMachPort?

    /// "default" | "sideways" | "vertical" (1.5.0's on/off switch counts as "sideways").
    static var mode: String {
        let d = UserDefaults.standard
        if let m = d.string(forKey: MiscSetting.shiftScrollMode) { return m }
        return d.bool(forKey: MiscSetting.shiftScroll) ? "sideways" : "default"
    }
    static var enabled: Bool { mode != "default" }
    nonisolated(unsafe) static var currentMode = "default"

    /// Follow the setting.
    func reload() {
        Self.currentMode = Self.mode
        if Self.enabled { start() } else if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    private func start() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true); return }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                DispatchQueue.main.async { MainActor.assumeIsolated { ShiftScroll.shared.reenable() } }
                return Unmanaged.passUnretained(event)
            }
            ShiftScroll.apply(ShiftScroll.currentMode, to: event)
            return Unmanaged.passUnretained(event)
        }, userInfo: nil)
        guard let tap else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func reenable() { if let tap, Self.enabled { CGEvent.tapEnable(tap: tap, enable: true) } }

    /// Shift held on a scroll: take it off (that alone makes it up/down again), then for "sideways" turn
    /// an up/down scroll into left/right.
    nonisolated static func apply(_ mode: String, to e: CGEvent) {
        guard mode != "default", e.flags.contains(.maskShift) else { return }
        var f = e.flags
        f.remove(.maskShift)
        e.flags = f
        guard mode == "sideways" else { return }
        let v = e.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let h = e.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let vp = e.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let hp = e.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        guard v != 0 || vp != 0, h == 0, hp == 0 else { return }
        let vf = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: v)
        e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: vp)
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: vf)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
    }
}
