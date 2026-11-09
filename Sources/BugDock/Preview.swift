import AppKit
import Combine
import SwiftUI
import BugOSKit

/// The hover popup above a taskbar button listing that app's windows.
@MainActor
final class PreviewController {
    private let tracker: WindowTracker
    private(set) unowned var bar: TaskbarController
    private let panel = FloatingPanel(level: .taskbarPopup)
    private var groupID: String?
    private var anchor: CGRect = .zero
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var overPopup = false
    private var sub: AnyCancellable?
    let peek: PeekController

    init(tracker: WindowTracker, bar: TaskbarController) {
        self.tracker = tracker
        self.bar = bar
        self.peek = PeekController(bar: bar)
        panel.hasShadow = true
        sub = tracker.$groups.receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// How many thumbnail cards fit side by side before wrapping to a new row.
    var cardsPerRow: Int { max(1, Int((bar.screen.frame.width - 40) / (Thumbnails.box.width + 20))) }

    func hoverBegan(groupID id: String, anchor: CGRect) {
        guard !bar.menuOpen, bar.style.showPreviews else { return }
        hideWork?.cancel()
        showWork?.cancel()
        if panel.isVisible {
            show(id, anchor)                       // sliding along the bar: switch instantly
        } else {
            let work = DispatchWorkItem { [weak self] in self?.show(id, anchor) }
            showWork = work
            let delay = UserDefaults.standard.object(forKey: DockSetting.previewDelay) as? Double ?? 0.35
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    func hoverEnded(groupID id: String) {
        showWork?.cancel()
        scheduleHide()
    }

    func popupHover(_ inside: Bool) {
        overPopup = inside
        if inside { hideWork?.cancel() } else { scheduleHide() }
    }

    func hide() {
        showWork?.cancel()
        hideWork?.cancel()
        peek.end()
        panel.orderOut(nil)
        groupID = nil
        overPopup = false
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.overPopup else { return }
            self.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func show(_ id: String, _ anchor: CGRect) {
        guard !bar.startMenu.isVisible else { return }
        if groupID != id {
            groupID = id
            panel.contentView = ClickThroughHostingView(rootView: PreviewView(tracker: tracker, groupID: id, controller: self))
        }
        self.anchor = anchor
        relayout()
        panel.orderFrontRegardless()
    }

    private func relayout() {
        guard let id = groupID, let view = panel.contentView else { return }
        guard tracker.groups.contains(where: { $0.id == id }) else { hide(); return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let screen = bar.screen.frame
        var x = anchor.midX - size.width / 2
        x = max(screen.minX + 8, min(screen.maxX - size.width - 8, x))
        let y = bar.panel.frame.maxY + 6
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

struct PreviewView: View {
    @ObservedObject var tracker: WindowTracker
    let groupID: String
    let controller: PreviewController

    var body: some View {
        let g = tracker.groups.first { $0.id == groupID }
        Group {
            if let g, !g.windows.isEmpty {
                let perRow = controller.cardsPerRow
                let rows = stride(from: 0, to: g.windows.count, by: perRow).map { Array(g.windows[$0..<min($0 + perRow, g.windows.count)]) }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows.indices, id: \.self) { r in
                        HStack(spacing: 4) {
                            ForEach(rows[r]) { w in
                                WindowCard(window: w, group: g, tracker: tracker, controller: controller)
                            }
                        }
                    }
                    if NowPlaying.players.contains(g.id) {
                        MediaButtons(player: g.id, nowPlaying: controller.bar.nowPlaying).frame(maxWidth: .infinity)
                    }
                }
                .padding(6)
            } else if let g {
                VStack(spacing: 2) {
                    Text(g.name)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).padding(.top, 7).padding(.bottom, NowPlaying.players.contains(g.id) ? 0 : 7)
                    if NowPlaying.players.contains(g.id) {
                        MediaButtons(player: g.id, nowPlaying: controller.bar.nowPlaying).padding(.horizontal, 6).padding(.bottom, 4)
                    }
                }
            }
        }
        .fixedSize()
        .background(VisualEffect(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
        .onHover { controller.popupHover($0) }
    }
}

/// One window: title bar with close button, live thumbnail underneath (Windows 11 style).
struct WindowCard: View {
    let window: TrackedWindow
    let group: AppGroup
    let tracker: WindowTracker
    let controller: PreviewController
    @State private var image: NSImage?
    @State private var hovering = false
    @State private var hoveringClose = false

    var body: some View {
        let box = Thumbnails.box
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(nsImage: IconCache.shared.icon(for: group)).resizable().frame(width: 16, height: 16)
                Text(window.title.isEmpty ? group.name : window.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Button {
                    WindowActions.close(window)
                    tracker.refreshSoon()
                } label: {
                    // macOS traffic-light close button: red dot, × only while hovered.
                    ZStack {
                        Circle()
                            .fill(Color(red: 1.0, green: 0.373, blue: 0.341))
                            .overlay(Circle().strokeBorder(Color(red: 0.88, green: 0.24, blue: 0.21), lineWidth: 0.5))
                        Image(systemName: "xmark")
                            .font(.system(size: 6.5, weight: .heavy))
                            .foregroundStyle(Color(red: 0.36, green: 0.02, blue: 0.0).opacity(0.85))
                            .opacity(hoveringClose ? 1 : 0)
                    }
                    .frame(width: 13, height: 13)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .onHover { hoveringClose = $0 }
            }
            .frame(height: 20)

            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                } else {
                    Image(nsImage: IconCache.shared.icon(for: group))
                        .resizable()
                        .frame(width: 48, height: 48)
                        .opacity(0.85)
                }
                if window.isMinimized {
                    VStack { Spacer(); Text("Minimized").font(.system(size: 10)).foregroundStyle(.secondary).padding(.bottom, 2) }
                }
            }
            .frame(width: box.width, height: box.height)
            .opacity(window.isMinimized ? 0.6 : 1)
        }
        .padding(8)
        .frame(width: box.width + 16)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(hovering ? 0.10 : 0)))
        .contentShape(Rectangle())
        .onTapGesture {
            controller.hide()
            WindowActions.focus(window)
            tracker.refreshSoon()
        }
        .onHover { h in
            hovering = h
            if h { controller.peek.hoverBegan(window) } else { controller.peek.hoverEnded(window) }
        }
        .task(id: "\(window.id)|\(window.isMinimized)") {
            image = Thumbnails.shared.cached(window)
            // Keep it live while the popup is open (about once a second).
            while !Task.isCancelled {
                if let img = await Thumbnails.shared.capture(window) { image = img }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// ⏮ ⏯ ⏭ under Spotify's or Music's preview, like Windows 11's thumbnail toolbar.
struct MediaButtons: View {
    let player: String
    @ObservedObject var nowPlaying: NowPlaying

    var body: some View {
        HStack(spacing: 6) {
            button("backward.fill", "Previous") { nowPlaying.send(.previous, to: player) }
            button(nowPlaying.isPlaying(player) ? "pause.fill" : "play.fill", nowPlaying.isPlaying(player) ? "Pause" : "Play", big: true) {
                nowPlaying.send(.playPause, to: player)
            }
            button("forward.fill", "Next") { nowPlaying.send(.next, to: player) }
        }
        .padding(.vertical, 2)
    }

    private func button(_ symbol: String, _ tip: String, big: Bool = false, action: @escaping () -> Void) -> some View {
        MediaButton(symbol: symbol, big: big, action: action).help(tip)
    }
}

private struct MediaButton: View {
    let symbol: String
    let big: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: big ? 15 : 12, weight: .semibold))
                .frame(width: big ? 44 : 36, height: 30)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(hovering ? 0.14 : 0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
    }
}
