// Shift to scroll sideways (BugOS › Misc; off by default): hold Shift while scrolling and up/down becomes
// left/right, like Windows. Some Mac apps already do this for mouse wheels; those scrolls arrive sideways
// already and are left as they are, so nothing gets flipped back.
import AppKit
import BugOSKit

@MainActor
final class ShiftScroll {
    static let shared = ShiftScroll()
    private var tap: CFMachPort?

    static var enabled: Bool { UserDefaults.standard.bool(forKey: MiscSetting.shiftScroll) }

    /// Follow the setting.
    func reload() {
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
            ShiftScroll.swapIfShifted(event)
            return Unmanaged.passUnretained(event)
        }, userInfo: nil)
        guard let tap else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func reenable() { if let tap, Self.enabled { CGEvent.tapEnable(tap: tap, enable: true) } }

    /// Shift held and a vertical-only scroll: make it horizontal (all three delta forms), and drop Shift so
    /// the app doesn't treat it as Shift-scroll on top.
    nonisolated static func swapIfShifted(_ e: CGEvent) {
        guard e.flags.contains(.maskShift) else { return }
        let v = e.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let h = e.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let vp = e.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let hp = e.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        guard (v != 0 || vp != 0), h == 0, hp == 0 else { return }
        let vf = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: v)
        e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: vp)
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: vf)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        var f = e.flags
        f.remove(.maskShift)
        e.flags = f
    }
}
