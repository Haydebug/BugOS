// Alt-Tab, Windows 11 style. Hold ⌥ (or ⌘, a setting) and tap Tab: a dark panel in the middle of the
// screen shows a live thumbnail of every window, most recently used first, with the next one picked.
// Tab / Shift-Tab and the arrow keys move; let go of ⌥ to switch to it; Esc cancels; click a card to
// switch straight to it.
//
// The keys come from an event tap (covered by BugOS's Accessibility permission): it's the only way to see
// ⌥ being let go of, and to take ⌘Tab over from the Mac's own switcher when that's the setting.
import AppKit
import BugOSKit
import Carbon.HIToolbox
import SwiftUI

struct AltTabItem: Identifiable {
    let window: TrackedWindow
    let appName: String
    let icon: NSImage
    var id: String { window.id }
}

@MainActor
final class AltTabModel: ObservableObject {
    @Published var items: [AltTabItem] = []
    @Published var selected = 0
    @Published var thumbs: [String: NSImage] = [:]
    var perRow = 5
}

@MainActor
final class AltTabController {
    static var shared: AltTabController?

    private let tracker: WindowTracker
    private unowned let bar: TaskbarController
    private let panel = FloatingPanel(level: NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1))
    private let model = AltTabModel()
    private var tap: CFMachPort?
    private var thumbTask: Task<Void, Never>?
    var isOpen: Bool { panel.isVisible }

    // Settings (read when they change).
    private(set) var enabled = true
    private(set) var useCommand = false
    private(set) var showMinimized = true
    private(set) var cardWidth: CGFloat = 240

    init(tracker: WindowTracker, bar: TaskbarController) {
        self.tracker = tracker
        self.bar = bar
        panel.hasShadow = true
        panel.contentView = ClickThroughHostingView(rootView: AltTabView(model: model) { [weak self] i in
            self?.model.selected = i
            self?.commit()
        })
        AltTabController.shared = self
        reload()
    }

    func reload() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: AltTabSetting.enabled) as? Bool ?? true
        useCommand = d.string(forKey: AltTabSetting.key) == "command"
        showMinimized = d.object(forKey: AltTabSetting.showMinimized) as? Bool ?? true
        switch d.string(forKey: AltTabSetting.size) {
        case "small": cardWidth = 190
        case "large": cardWidth = 300
        default: cardWidth = 240
        }
        if enabled { installTap() } else if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if !enabled { cancel() }
    }

    // MARK: Keys

    private func installTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true); return }
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue))
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, type, event, _ in
            // Runs on the main run loop.
            MainActor.assumeIsolated {
                guard let me = AltTabController.shared else { return Unmanaged.passUnretained(event) }
                return me.handle(type, event) ? nil : Unmanaged.passUnretained(event)
            }
        }, userInfo: nil)
        guard let tap else { NSLog("BugDock: Alt-Tab needs Accessibility"); return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private var holdFlag: CGEventFlags { useCommand ? .maskCommand : .maskAlternate }

    /// True = swallow the event.
    private func handle(_ type: CGEventType, _ e: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard enabled else { return false }
        let flags = e.flags
        if type == .flagsChanged {
            if isOpen && !flags.contains(holdFlag) { commit() }   // let go of ⌥: switch
            return false
        }
        let key = Int(e.getIntegerValueField(.keyboardEventKeycode))
        let held = flags.contains(holdFlag)
        // The other "real" modifiers mustn't be down (Shift is fine: it goes backwards).
        let others: CGEventFlags = useCommand ? [.maskAlternate, .maskControl] : [.maskCommand, .maskControl]
        if key == kVK_Tab && held && flags.intersection(others).isEmpty {
            let back = flags.contains(.maskShift)
            if isOpen { move(back ? -1 : 1) } else { open(backwards: back) }
            return true
        }
        guard isOpen else { return false }
        switch key {
        case kVK_LeftArrow: move(-1); return true
        case kVK_RightArrow: move(1); return true
        case kVK_UpArrow: move(-model.perRow); return true
        case kVK_DownArrow: move(model.perRow); return true
        case kVK_Escape: cancel(); return true
        case kVK_Return, kVK_Space: commit(); return true
        default: return true   // nothing else reaches apps while the switcher is up
        }
    }

    // MARK: Open / move / switch

    /// Windows, most recently used first: the front app's windows front to back, then the other apps in
    /// the order you last used them.
    private func windowsInOrder() -> [AltTabItem] {
        let groups = tracker.groups.filter { !$0.windows.isEmpty }
        let recent = AppHistory.shared.recentPIDs
        func rank(_ g: AppGroup) -> Int { g.pids.compactMap { recent.firstIndex(of: $0) }.min() ?? Int.max }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let sorted = groups.sorted { a, b in
            let af = front.map { a.pids.contains($0) } ?? false, bf = front.map { b.pids.contains($0) } ?? false
            if af != bf { return af }
            return rank(a) < rank(b)
        }
        var out: [AltTabItem] = []
        for g in sorted {
            let icon = IconCache.shared.icon(for: g)
            let wins = g.windows.filter { showMinimized || !$0.isMinimized }
            // Minimized ones after the app's open windows.
            for w in wins.filter({ !$0.isMinimized }) + wins.filter(\.isMinimized) {
                out.append(AltTabItem(window: w, appName: g.name, icon: icon))
            }
        }
        return out
    }

    private func open(backwards: Bool) {
        let items = windowsInOrder()
        guard !items.isEmpty else { return }
        bar.preview.hide()
        model.items = items
        model.thumbs = Dictionary(uniqueKeysWithValues: items.compactMap { i in Thumbnails.shared.cached(i.window).map { (i.id, $0) } })
        // Like Windows: the first Tab picks the window you were in before this one.
        model.selected = items.count > 1 ? (backwards ? items.count - 1 : 1) : 0
        layout()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        loadThumbnails()
    }

    private func layout() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? bar.screen
        let vf = screen.visibleFrame
        let card = AltTabView.cardSize(width: cardWidth)
        let pad: CGFloat = 16, gap: CGFloat = 8
        let maxPerRow = max(1, Int((vf.width * 0.9 - pad * 2 + gap) / (card.width + gap)))
        let perRow = min(maxPerRow, model.items.count)
        model.perRow = perRow
        let rows = Int(ceil(Double(model.items.count) / Double(perRow)))
        let maxRows = max(1, Int((vf.height * 0.85 - pad * 2 + gap) / (card.height + gap)))
        let shownRows = min(rows, maxRows)
        let w = CGFloat(perRow) * card.width + CGFloat(perRow - 1) * gap + pad * 2
        let h = CGFloat(shownRows) * card.height + CGFloat(shownRows - 1) * gap + pad * 2
        panel.contentView = ClickThroughHostingView(rootView: AltTabView(model: model, cardWidth: cardWidth, scrolls: rows > maxRows) { [weak self] i in
            self?.model.selected = i
            self?.commit()
        })
        panel.setFrame(NSRect(x: (vf.midX - w / 2).rounded(), y: (vf.midY - h / 2).rounded(), width: w, height: h), display: true)
    }

    private func loadThumbnails() {
        thumbTask?.cancel()
        let items = model.items
        thumbTask = Task { @MainActor [weak self] in
            for i in items {
                if Task.isCancelled { return }
                if let img = await Thumbnails.shared.capture(i.window) { self?.model.thumbs[i.id] = img }
            }
        }
    }

    private func move(_ d: Int) {
        let n = model.items.count
        guard n > 0 else { return }
        model.selected = ((model.selected + d) % n + n) % n
    }

    private func commit() {
        guard isOpen else { return }
        let item = model.items.indices.contains(model.selected) ? model.items[model.selected] : nil
        hide()
        if let item { WindowActions.focus(item.window); tracker.refreshSoon() }
    }

    private func cancel() { if isOpen { hide() } }

    private func hide() {
        thumbTask?.cancel()
        panel.orderOut(nil)
    }
}

// MARK: The panel

struct AltTabView: View {
    @ObservedObject var model: AltTabModel
    var cardWidth: CGFloat = 240
    var scrolls = false
    let onPick: (Int) -> Void

    init(model: AltTabModel, cardWidth: CGFloat = 240, scrolls: Bool = false, onPick: @escaping (Int) -> Void) {
        self.model = model; self.cardWidth = cardWidth; self.scrolls = scrolls; self.onPick = onPick
    }

    /// Card = title row + thumbnail (16:10) + padding.
    static func cardSize(width: CGFloat) -> CGSize { CGSize(width: width, height: 28 + (width - 16) * 0.625 + 16) }

    var body: some View {
        let card = Self.cardSize(width: cardWidth)
        let columns = Array(repeating: GridItem(.fixed(card.width), spacing: 8), count: max(1, model.perRow))
        let grid = LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                AltTabCard(item: item, thumb: model.thumbs[item.id], selected: model.selected == i, width: cardWidth)
                    .id(i)
                    .onHover { if $0 { model.selected = i } }   // the pointer picks too, like Windows
                    .onTapGesture { onPick(i) }
            }
        }
        .padding(16)
        Group {
            if scrolls {
                ScrollViewReader { proxy in
                    ScrollView { grid }
                        .scrollIndicators(.hidden)
                        .onChange(of: model.selected) { _, i in withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(i) } }
                }
            } else {
                grid
            }
        }
        .background(VisualEffect(material: .hudWindow))
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }
}

/// One window: app icon and title on top, the thumbnail below; picked = a white ring (Windows 11).
struct AltTabCard: View {
    let item: AltTabItem
    let thumb: NSImage?
    let selected: Bool
    let width: CGFloat

    var body: some View {
        let thumbW = width - 16, thumbH = thumbW * 0.625
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(nsImage: item.icon).resizable().frame(width: 16, height: 16)
                Text(item.window.title.isEmpty ? item.appName : item.window.title)
                    .font(.system(size: 12)).foregroundStyle(.white).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .frame(height: 22)
            ZStack {
                if let thumb {
                    Image(nsImage: thumb).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.06))
                    Image(nsImage: item.icon).resizable().frame(width: 48, height: 48)
                }
                if item.window.isMinimized {
                    VStack { Spacer(); Text("Minimized").font(.system(size: 10)).foregroundStyle(.secondary).padding(.bottom, 4) }
                }
            }
            .frame(width: thumbW, height: thumbH)
            .opacity(item.window.isMinimized ? 0.6 : 1)
        }
        .padding(8)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(selected ? 0.12 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(selected ? Color.white.opacity(0.9) : .clear, lineWidth: 2.5))
        .contentShape(Rectangle())
    }
}
