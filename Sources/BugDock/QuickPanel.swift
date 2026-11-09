// Quick Access, for the trackpad gesture (its own list of shortcuts, separate from the quick corner's): swipe two fingers in from the right edge and
// a Liquid Glass column of the same shortcuts slides in from the right side of the screen, centred top to
// bottom (like Notification Center). Slide your fingers down to move the highlight, lift to open it, swipe
// back out to slide it away. The pointer works too: hover and click. (The mouse corner keeps the fan.)
import AppKit
import BugOSKit
import SwiftUI
import Carbon.HIToolbox

@MainActor
final class QuickPanelModel: ObservableObject {
    @Published var items: [QuickItem] = []
    @Published var highlighted: String?
}

@MainActor
final class QuickPanelController {
    private unowned let corner: QuickCornerController
    private let bar: TaskbarController
    private let panel = KeyablePanel(level: .taskbarPopup)   // takes the keyboard when opened by its shortcut
    private let model = QuickPanelModel()
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var localKeys: Any?
    private var host: NSView!
    /// Opened from the keyboard: the app that was in front, to hand focus back to if nothing is picked.
    private var returnTo: NSRunningApplication?

    static let width: CGFloat = 280
    static let row: CGFloat = 50
    static let inset: CGFloat = 14
    static let corner: CGFloat = 26
    static func height(for count: Int) -> CGFloat { CGFloat(count) * row + inset * 2 + 30 }

    init(corner: QuickCornerController, bar: TaskbarController) {
        self.corner = corner
        self.bar = bar
        let host = ClickThroughHostingView(rootView: QuickPanelView(model: model) { [weak self] item in self?.run(item) })
        self.host = host
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.corner
            glass.style = .regular
            glass.contentView = host
            panel.contentView = glass
        } else {
            let fx = NSVisualEffectView()
            fx.material = .hudWindow
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = Self.corner
            fx.layer?.masksToBounds = true
            host.frame = fx.bounds
            host.autoresizingMask = [.width, .height]
            fx.addSubview(host)
            panel.contentView = fx
        }
        panel.hasShadow = true
        panel.acceptsMouseMovedEvents = true
    }

    var isOpen: Bool { panel.isVisible }

    /// Shown: right side of the screen, centred top to bottom, top shortcut highlighted.
    func open(withKeyboard: Bool = false) {
        guard !isOpen else { return }
        // Top of the list = top of the fan (the stored order is nearest-the-corner first).
        model.items = corner.items(for: QuickCornerCatalog.access).reversed()
        model.highlighted = model.items.first?.id
        let h = Self.height(for: model.items.count)
        // The screen you're on (where the pointer is), not always the main one.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? bar.screen
        let s = screen.visibleFrame
        let frame = NSRect(x: s.maxX - Self.width - 14, y: (s.midY - h / 2).rounded(), width: Self.width, height: h)
        // Slide in from just past the right edge.
        panel.setFrame(frame.offsetBy(dx: Self.width * 0.6, dy: 0), display: false)
        host.frame = NSRect(origin: .zero, size: frame.size)   // the glass doesn't size its content itself
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.2
            c.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.panel.invalidateShadow() }
        }
        if withKeyboard {
            // Take the keyboard: ↑ ↓ pick, Return opens, Esc closes.
            returnTo = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self else { return e }
                return MainActor.assumeIsolated {
                    switch Int(e.keyCode) {
                    case kVK_UpArrow: self.step(-1); return nil
                    case kVK_DownArrow: self.step(1); return nil
                    case kVK_Return, kVK_ANSI_KeypadEnter: self.runHighlighted(); return nil
                    case kVK_Escape: self.close(); return nil
                    default: return e
                    }
                }
            }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { MainActor.assumeIsolated { self?.close() } }   // Esc
        }
    }

    /// Slides back out to the right.
    func close() { close(handingBack: true) }

    private func close(handingBack: Bool) {
        guard isOpen else { return }
        for m in [clickMonitor, keyMonitor, localKeys].compactMap({ $0 }) { NSEvent.removeMonitor(m) }
        clickMonitor = nil; keyMonitor = nil; localKeys = nil
        // Opened from the keyboard and nothing picked: back to the app you were in.
        if handingBack, let app = returnTo { app.activate() }
        returnTo = nil
        let out = panel.frame.offsetBy(dx: Self.width * 0.6, dy: 0)
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.16
            c.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(out, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.panel.orderOut(nil) }
        }
    }

    /// 0 = top shortcut … 1 = bottom (from the fingers sliding down).
    func highlight(fraction: Double) {
        guard !model.items.isEmpty else { return }
        let i = Int((max(0, min(1, fraction)) * Double(model.items.count - 1)).rounded())
        if model.highlighted != model.items[i].id { model.highlighted = model.items[i].id }
    }

    func runHighlighted() {
        guard isOpen, let id = model.highlighted, let item = model.items.first(where: { $0.id == id }) else { return }
        run(item)
    }

    private func run(_ item: QuickItem) {
        close(handingBack: false)
        item.action()
    }

    private func step(_ d: Int) {
        guard !model.items.isEmpty else { return }
        let i = model.items.firstIndex { $0.id == model.highlighted } ?? -1
        model.highlighted = model.items[max(0, min(model.items.count - 1, i + d))].id
    }
}

struct QuickPanelView: View {
    @ObservedObject var model: QuickPanelModel
    let onSelect: (QuickItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Quick Access").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).frame(height: 30, alignment: .center)
            ForEach(model.items) { item in
                QuickPanelRow(item: item, highlighted: model.highlighted == item.id) { onSelect(item) }
                    .onHover { h in if h { model.highlighted = item.id } }
            }
        }
        .padding(QuickPanelController.inset)
        .frame(width: QuickPanelController.width, height: QuickPanelController.height(for: model.items.count), alignment: .topLeading)
    }
}

struct QuickPanelRow: View {
    let item: QuickItem
    let highlighted: Bool
    let action: () -> Void

    var body: some View {
        let d = UserDefaults.standard
        let tint = d.string(forKey: QuickCornerCatalog.tileColorKey).flatMap(BugOSColor.color(hex:)).map { Color(nsColor: $0) }
        let glyph = d.string(forKey: QuickCornerCatalog.iconColorKey).flatMap(BugOSColor.color(hex:)).map { Color(nsColor: $0) } ?? .primary
        Button(action: action) {
            HStack(spacing: 12) {
                Group {
                    switch item.icon {
                    case .image(let img):
                        Image(nsImage: img).resizable().interpolation(.high)
                    case .symbol, .glyph:
                        ZStack {
                            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint?.opacity(0.6) ?? Color.primary.opacity(0.08))
                            QuickGlyph(icon: item.icon, size: 16).foregroundStyle(glyph)
                        }
                    }
                }
                .frame(width: 34, height: 34)
                Text(item.label).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: QuickPanelController.row)
            .background {
                if highlighted {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(nsColor: BugOSColor.accent).opacity(0.85))
                }
            }
            .foregroundStyle(highlighted ? Color.white : Color.primary)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.1), value: highlighted)
        }
        .buttonStyle(.plain)
    }
}
