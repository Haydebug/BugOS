// The BugOS page: what you see when you open BugOS. Version, permissions, settings for each part,
// start at login, and Uninstall. Settings that belong to a part are written to that part's preferences
// and the part is told to pick them up straight away.
import AppKit
import BugOSKit
import SwiftUI
import UniformTypeIdentifiers

/// Another app's preferences (a part's), read and written from BugOS.
struct PartPrefs {
    let domain: String
    let changed: Notification.Name

    func value<T>(_ key: String, default d: T) -> T {
        CFPreferencesAppSynchronize(domain as CFString)
        return CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? T ?? d
    }
    func set(_ key: String, _ value: Any?) {
        CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)
        DistributedNotificationCenter.default().postNotificationName(changed, object: nil, userInfo: nil, deliverImmediately: true)
    }
    /// Ask the part to drop (or bring back) its global shortcuts, so recording a new one isn't
    /// swallowed by the old one.
    /// Ask the running part to do something (e.g. "spotify:connect").
    func command(_ c: String) {
        DistributedNotificationCenter.default().postNotificationName(changed, object: c, userInfo: nil, deliverImmediately: true)
    }
    func pauseShortcuts(_ paused: Bool) {
        DistributedNotificationCenter.default().postNotificationName(changed, object: paused ? "pause" : nil,
                                                                     userInfo: nil, deliverImmediately: true)
    }
    func binding<T>(_ key: String, default d: T, onSet: (() -> Void)? = nil) -> Binding<T> {
        Binding(get: { value(key, default: d) }, set: { set(key, $0); onSet?() })
    }
}

let dockPrefs = PartPrefs(domain: BugOSID.dock, changed: BugOSID.dockSettingsChanged)
let explorerPrefs = PartPrefs(domain: BugOSID.explorer, changed: BugOSID.explorerSettingsChanged)
let squigglePrefs = PartPrefs(domain: BugOSID.squiggle, changed: BugOSID.squiggleSettingsChanged)

enum PageSection: String, CaseIterable, Identifiable {
    case general, features, permissions, taskbar, altTab, quickCorner, quickAccess, explorer, squiggle
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .features: "Features"
        case .squiggle: "Squiggle"
        case .permissions: "Permissions"
        case .taskbar: "Taskbar"
        case .quickCorner: "Quick Corner"
        case .quickAccess: "Quick Access"
        case .altTab: "Alt-Tab"
        case .explorer: "File Explorer"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .features: "switch.2"
        case .squiggle: "scribble.variable"
        case .permissions: "lock.shield"
        case .taskbar: "dock.rectangle"
        case .quickCorner: "square.stack.3d.up"
        case .quickAccess: "hand.draw"
        case .altTab: "rectangle.on.rectangle"
        case .explorer: "folder"
        }
    }
}

@MainActor
final class PageModel: ObservableObject {
    @Published var section: PageSection
    @Published var perms: [Perm: Bool] = [:]
    @Published var refresh = 0          // bumped to redraw values read straight from preferences
    private var initial: [Perm: Bool] = [:]
    private var timer: Timer?

    static weak var current: PageModel?

    init(section: PageSection) {
        self.section = section
        defer { PageModel.current = self }
        readPerms()
        initial = perms
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readPerms() }
        }
    }

    func readPerms() {
        var p: [Perm: Bool] = [:]
        for x in Perm.allCases { p[x] = Permissions.isOn(x) }
        if p != perms { perms = p }
    }

    var missingRequired: Bool { Perm.allCases.contains { !$0.optional && perms[$0] != true } }
    /// A permission went from off to on while the page was open: the parts restart to use it.
    var newlyGranted: Bool { Perm.allCases.contains { initial[$0] != true && perms[$0] == true } }

    func stop() { timer?.invalidate() }
}

struct PageView: View {
    @ObservedObject var model: PageModel
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("BugOS").font(.system(size: 15, weight: .semibold))
                        Text("Version \(SystemChanges.version)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 14)
                ForEach(PageSection.allCases) { s in
                    SidebarRow(section: s, selected: model.section == s,
                               warning: s == .permissions && model.missingRequired) { model.section = s }
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 200)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))

            Divider()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(model.section.title).font(.system(size: 20, weight: .semibold)).id(model.refresh)
                        switch model.section {
                        case .general: GeneralSection()
                        case .permissions: PermissionsSection(model: model)
                        case .taskbar: TaskbarSection()
                        case .quickCorner: QuickCornerSection()
                        case .quickAccess: QuickAccessSection()
                        case .altTab: AltTabSection()
                        case .explorer: ExplorerSection()
                        case .features: FeaturesSection()
                        case .squiggle: SquiggleSection()
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("\(model.section.rawValue)-\(model.refresh)")
                }
                Divider()
                HStack {
                    if model.newlyGranted {
                        Label("BugOS restarts its parts when you click Done, so new permissions take effect.",
                              systemImage: "arrow.clockwise")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Done", action: onDone).keyboardShortcut(.defaultAction).controlSize(.large)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
        .frame(width: 780, height: 560)
    }
}

struct SidebarRow: View {
    let section: PageSection
    let selected: Bool
    let warning: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.symbol).frame(width: 18)
                Text(section.title)
                Spacer()
                if warning { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange) }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A rounded group of rows, like System Settings.
struct SettingsGroup<Content: View>: View {
    var footer: String? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
            if let footer {
                Text(footer).font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ToggleRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 16)
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

struct RowDivider: View { var body: some View { Divider().padding(.leading, 14) } }

// MARK: Sections

/// The accent colour is copied into every part's preferences (each reads its own).
func setAccent(_ hex: String?) {
    UserDefaults.standard.set(hex, forKey: BugOSColor.accentKey)
    for p in [dockPrefs, explorerPrefs, squigglePrefs] { p.set(BugOSColor.accentKey, hex) }
}

struct GeneralSection: View {
    @State private var accent: String? = UserDefaults.standard.string(forKey: BugOSColor.accentKey)
    @State private var login = SystemChanges.startsAtLogin
    @State private var dock = SystemChanges.dockTucked
    @State private var confirming = false
    @State private var keepSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("BugOS \(SystemChanges.version)").font(.system(size: 15, weight: .semibold))
                        Text("A Windows 11-style taskbar, File Explorer and Squiggle for your Mac.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
            }
            UpdatesGroup()
            SettingsGroup(footer: "Used for the taskbar's running-app marks, File Explorer's selection and highlights, and Squiggle.") {
                ColorRow(title: "Accent colour", noneLabel: "The Mac's accent colour", defaultColor: Color(nsColor: .controlAccentColor), hex: Binding(get: { accent }, set: { accent = $0; setAccent($0) }))
            }
            SettingsGroup(footer: "The Mac Dock would sit on top of the taskbar. Tucking it away moves it to the left, hides it, and turns off the bottom-right hot corner (the quick corner lives there). Turning this off puts your Dock back exactly how it was.") {
                ToggleRow(title: "Start BugOS when you log in",
                          isOn: Binding(get: { login }, set: { login = $0; SystemChanges.setStartsAtLogin($0) }))
                RowDivider()
                ToggleRow(title: "Tuck the Mac Dock away",
                          isOn: Binding(get: { dock }, set: { dock = $0; SystemChanges.setDockTucked($0) }))
            }
            SettingsGroup(footer: "Something stuck? Restart just that part; your windows and settings stay.") {
                HStack(spacing: 10) {
                    Text("Restart").font(.system(size: 13))
                    Spacer()
                    Button("Taskbar") { Supervisor.shared.restart(.dock) }.disabled(!Part.dock.enabled)
                    Button("File Explorer") { Supervisor.shared.restart(.explorer) }.disabled(!Part.explorer.enabled)
                    Button("Squiggle") { Supervisor.shared.restart(.squiggle) }.disabled(!Part.squiggle.enabled)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                RowDivider()
                HStack {
                    Text("BugOS log").font(.system(size: 13))
                    Spacer()
                    Button("Show Log") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Bug OS.log"))
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            SettingsGroup(footer: "Removes BugOS and puts everything back: your Dock and hot corner, Finder for folders, the login item, and its permission entries.") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Uninstall BugOS").font(.system(size: 13))
                        Text("Your screenshots and recordings are never deleted.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Uninstall…", role: .destructive) { confirming = true }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .sheet(isPresented: $confirming) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Uninstall BugOS?").font(.system(size: 15, weight: .semibold))
                Text("BugOS quits, its taskbar, File Explorer and Squiggle go away, and your Mac goes back to how it was: Dock, hot corner, Finder for folders, no login item, no permission entries.")
                    .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                Toggle("Keep my BugOS settings (pinned apps, saved tabs) in case I reinstall", isOn: $keepSettings)
                    .font(.system(size: 12.5))
                HStack {
                    Spacer()
                    Button("Cancel") { confirming = false }.keyboardShortcut(.cancelAction)
                    Button("Uninstall", role: .destructive) {
                        confirming = false
                        SystemChanges.uninstall(keepSettings: keepSettings)
                    }
                }
            }
            .padding(20)
            .frame(width: 420)
        }
    }
}

struct UpdatesGroup: View {
    @ObservedObject private var updater = Updater.shared
    @State private var auto = Updater.autoCheck

    var body: some View {
        SettingsGroup(footer: "New versions come from github.com/\(Updater.repo). Your settings and permissions stay as they are.") {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: isAvailable ? .semibold : .regular))
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(isFailed ? Color.orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                switch updater.state {
                case .checking, .installing:
                    ProgressView().controlSize(.small)
                case .downloading(let f):
                    ProgressView(value: f).frame(width: 120)
                case .available:
                    Button("Install & Restart") { updater.install() }.keyboardShortcut(.defaultAction)
                default:
                    Button("Check for Updates") { updater.check() }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            if case .available(let r) = updater.state, !r.notes.isEmpty {
                RowDivider()
                ScrollView {
                    Text(r.notes).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: 120)
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            RowDivider()
            ToggleRow(title: "Check for updates automatically", detail: "Once a day. BugOS shows this page when a new version is out.",
                      isOn: Binding(get: { auto }, set: { auto = $0; Updater.autoCheck = $0 }))
        }
    }

    private var isAvailable: Bool { if case .available = updater.state { return true } else { return false } }
    private var isFailed: Bool { if case .failed = updater.state { return true } else { return false } }
    private var title: String {
        if case .available(let r) = updater.state { return "BugOS \(r.version) is available" }
        return "BugOS \(updater.current)"
    }
    private var subtitle: String {
        switch updater.state {
        case .checking: return "Checking…"
        case .upToDate: return "You're up to date."
        case .available: return "You have \(updater.current)."
        case .downloading: return "Downloading…"
        case .installing: return "Installing. BugOS will reopen in a moment."
        case .failed(let m): return m
        case .idle:
            if let d = updater.lastChecked {
                return "Last checked \(d.formatted(.relative(presentation: .named)))."
            }
            return "Not checked yet."
        }
    }
}

struct PermissionsSection: View {
    @ObservedObject var model: PageModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("macOS asks once for each of these. They're all listed under \u{201C}BugOS\u{201D}: one switch covers the taskbar, File Explorer and Squiggle.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SettingsGroup {
                ForEach(Array(Perm.allCases.enumerated()), id: \.element) { i, p in
                    if i > 0 { RowDivider() }
                    PermRow(perm: p, on: model.perms[p] == true)
                }
            }
            HStack(spacing: 10) {
                DragIcon().frame(width: 30, height: 30)
                Text("BugOS not in a list? Drag this icon into it, or click + and choose Applications › BugOS.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Music controls: the first time a song plays, macOS asks if BugOS may control Spotify or Music. Click OK.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PermRow: View {
    let perm: Perm
    let on: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: perm.symbol).font(.system(size: 16)).frame(width: 24).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(perm.title).font(.system(size: 13, weight: .medium))
                    if perm.optional {
                        Text("Optional").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                Text(perm.why).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if on {
                Label("On", systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green).frame(width: 86, alignment: .trailing)
            } else {
                Button("Turn On…") { Permissions.request(perm) }.frame(width: 86, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

struct TaskbarSection: View {
    @State private var peek: Double = dockPrefs.value("peekStrength", default: 0.5)
    @State private var spotifyID: String = dockPrefs.value(DockSetting.spotifyClientID, default: "")
    @State private var spotifyOn: Bool = dockPrefs.value("spotifyConnected", default: false)
    @State private var allDisplays: Bool = dockPrefs.value(DockSetting.allDisplays, default: true)
    @State private var appsOn: String = dockPrefs.value(DockSetting.barAppsOn, default: "all")
    private let spotifyTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    @State private var size: String = dockPrefs.value(DockSetting.barSize, default: "medium")
    @State private var align: String = dockPrefs.value(DockSetting.barAlignment, default: "center")
    @State private var background: String = dockPrefs.value(DockSetting.barBackground, default: "clear")
    @State private var opacity: Double = dockPrefs.value(DockSetting.barOpacity, default: 0.8)
    @State private var previews: Bool = dockPrefs.value(DockSetting.showPreviews, default: true)
    @State private var delay: Double = dockPrefs.value(DockSetting.previewDelay, default: 0.35)
    @State private var shape: String = dockPrefs.value(DockSetting.barShape, default: "full")
    @State private var corner: Double = dockPrefs.value(DockSetting.barCorner, default: 14)
    @State private var tint: String? = dockPrefs.value(DockSetting.barTint, default: nil as String?)
    @State private var indicator: String = dockPrefs.value(DockSetting.indicator, default: "pill")
    @State private var reset = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PartOffBanner(part: .dock)
            Text("Look").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            SettingsGroup {
                PickerRow(title: "Size", selection: Binding(get: { size }, set: { size = $0; dockPrefs.set(DockSetting.barSize, $0) }),
                          options: [("small", "Small"), ("medium", "Medium"), ("large", "Large")])
                RowDivider()
                PickerRow(title: "Icon alignment", selection: Binding(get: { align }, set: { align = $0; dockPrefs.set(DockSetting.barAlignment, $0) }),
                          options: [("center", "Center"), ("left", "Left")])
                RowDivider()
                PickerRow(title: "Background", detail: "Clear shows your wallpaper behind the icons.",
                          selection: Binding(get: { background }, set: { background = $0; dockPrefs.set(DockSetting.barBackground, $0) }),
                          options: [("clear", "Clear"), ("translucent", "Blurred"), ("solid", "Solid")])
                RowDivider()
                SliderRow(title: "Background opacity", value: Binding(get: { opacity }, set: {
                    opacity = $0; dockPrefs.set(DockSetting.barOpacity, $0)
                }), range: 0.1...1, format: { "\(Int(($0 * 100).rounded()))%" })
                .disabled(background == "clear").opacity(background == "clear" ? 0.45 : 1)
                RowDivider()
                ColorRow(title: "Background colour", noneLabel: "Dark grey", defaultColor: Color(white: 0.11), hex: Binding(get: { tint }, set: {
                    tint = $0; dockPrefs.set(DockSetting.barTint, $0)
                }))
                .disabled(background == "clear").opacity(background == "clear" ? 0.45 : 1)
                RowDivider()
                PickerRow(title: "Shape", detail: "Floating leaves a gap around a rounded bar.",
                          selection: Binding(get: { shape }, set: { shape = $0; dockPrefs.set(DockSetting.barShape, $0) }),
                          options: [("full", "Edge to edge"), ("floating", "Floating")])
                RowDivider()
                SliderRow(title: "Corner roundness", value: Binding(get: { corner }, set: {
                    corner = $0; dockPrefs.set(DockSetting.barCorner, $0)
                }), range: 0...24, step: 1, format: { "\(Int($0))pt" })
                .disabled(shape != "floating").opacity(shape == "floating" ? 1 : 0.45)
                RowDivider()
                PickerRow(title: "Running app mark", selection: Binding(get: { indicator }, set: {
                    indicator = $0; dockPrefs.set(DockSetting.indicator, $0)
                }), options: [("pill", "Pill"), ("dot", "Dot"), ("line", "Line"), ("none", "None")])
            }
            Text("Multiple displays").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            SettingsGroup(footer: "Like Windows: a taskbar along the bottom of every screen. The main screen's keeps the music, the quick corner and Alt-Tab.") {
                ToggleRow(title: "Show the taskbar on all displays",
                          isOn: Binding(get: { allDisplays }, set: { allDisplays = $0; dockPrefs.set(DockSetting.allDisplays, $0) }))
                RowDivider()
                PickerRow(title: "Show apps on", detail: appsOn == "where"
                            ? "Each app on the taskbar of the screen its window is on; pinned apps on the main one."
                            : "Every app on every taskbar.",
                          selection: Binding(get: { appsOn }, set: { appsOn = $0; dockPrefs.set(DockSetting.barAppsOn, $0) }),
                          options: [("all", "All taskbars"), ("where", "Where the window is")])
                .disabled(!allDisplays).opacity(allDisplays ? 1 : 0.45)
            }
            Text("Behavior").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            SettingsGroup {
                ToggleRow(title: "Show music on the taskbar", detail: "What's playing in Spotify or Music, on the side of the taskbar.",
                          isOn: dockPrefs.binding(DockSetting.showNowPlaying, default: true))
                RowDivider()
                ToggleRow(title: "Show apps with no open windows",
                          isOn: dockPrefs.binding("showWindowlessApps", default: false))
                RowDivider()
                ToggleRow(title: "Keep windows above the taskbar", detail: "Nudges windows up so the taskbar never covers them.",
                          isOn: dockPrefs.binding("fitWindowsAboveBar", default: true))
                RowDivider()
                ToggleRow(title: "Window previews", detail: "Live thumbnails when the pointer rests on a taskbar button.",
                          isOn: Binding(get: { previews }, set: { previews = $0; dockPrefs.set(DockSetting.showPreviews, $0) }))
                RowDivider()
                SliderRow(title: "Preview delay", value: Binding(get: { delay }, set: {
                    delay = $0; dockPrefs.set(DockSetting.previewDelay, $0)
                }), range: 0...1.5, step: 0.05, format: { $0 < 0.01 ? "Instant" : String(format: "%.2fs", $0) })
                .disabled(!previews).opacity(previews ? 1 : 0.45)
            }
            SettingsGroup(footer: "How much other windows fade when you hover a window's preview.") {
                HStack {
                    Text("Peek strength").font(.system(size: 13))
                    Spacer()
                    Picker("", selection: Binding(get: { peek }, set: { peek = $0; dockPrefs.set("peekStrength", $0) })) {
                        Text("Light").tag(0.3); Text("Medium").tag(0.5); Text("Strong").tag(0.75); Text("Full").tag(1.0)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            SettingsGroup(footer: "Optional. To like songs from the taskbar, create an app at developer.spotify.com with the redirect URI http://127.0.0.1:43821/callback, paste its client id here, then click Connect.") {
                HStack {
                    Text("Spotify client id").font(.system(size: 13))
                    Spacer()
                    TextField("none", text: Binding(get: { spotifyID }, set: {
                        spotifyID = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        dockPrefs.set(DockSetting.spotifyClientID, spotifyID.isEmpty ? nil : spotifyID)
                    }))
                    .textFieldStyle(.roundedBorder).frame(width: 280)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                RowDivider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Spotify account").font(.system(size: 13))
                        Text(spotifyOn ? "Connected: the heart on the taskbar likes songs." : "Not connected.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if spotifyOn {
                        Button("Disconnect") { dockPrefs.command("spotify:disconnect"); spotifyOn = false }
                    } else {
                        Button("Connect…") { dockPrefs.command("spotify:connect") }.disabled(spotifyID.isEmpty)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            HStack {
                Spacer()
                Button("Reset taskbar look") {
                    for k in [DockSetting.barSize, DockSetting.barAlignment, DockSetting.barBackground, DockSetting.barOpacity,
                              DockSetting.showPreviews, DockSetting.previewDelay, DockSetting.barShape, DockSetting.barCorner,
                              DockSetting.barTint, DockSetting.indicator] { dockPrefs.set(k, nil) }
                    size = "medium"; align = "center"; background = "clear"; opacity = 0.8; previews = true; delay = 0.35
                    shape = "full"; corner = 14; tint = nil; indicator = "pill"
                }
            }
        }
        .onReceive(spotifyTimer) { _ in spotifyOn = dockPrefs.value("spotifyConnected", default: false) }   // after you sign in
    }
}

struct QuickCornerSection: View {
    @State private var enabled: Bool = dockPrefs.value("quickCornerEnabled", default: true)
    @State private var tile: String? = dockPrefs.value(QuickCornerCatalog.tileColorKey, default: nil as String?)
    @State private var glyph: String? = dockPrefs.value(QuickCornerCatalog.iconColorKey, default: nil as String?)
    @State private var curve: Double = dockPrefs.value(QuickCornerCatalog.curveKey, default: 1.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PartOffBanner(part: .dock)
            SettingsGroup(footer: "Rest the pointer in the bottom-right corner of the screen and these shortcuts fan up from it. (The trackpad swipe has its own list: Quick Access.)") {
                ToggleRow(title: "Quick corner", isOn: Binding(get: { enabled }, set: {
                    enabled = $0; dockPrefs.set("quickCornerEnabled", $0); SystemChanges.syncNotificationSwipe()
                }))
            }
            SettingsGroup(footer: "The shortcut you point at is outlined in your accent colour (General › Accent colour). Colours apply to Quick Access too.") {
                SliderRow(title: "Curve", value: Binding(get: { curve }, set: {
                    curve = $0; dockPrefs.set(QuickCornerCatalog.curveKey, $0)
                }), range: 0...2, step: 0.25, format: { $0 < 0.01 ? "Straight" : $0 < 0.9 ? "Gentle" : $0 < 1.1 ? "Curved" : "Very curved" })
                RowDivider()
                ColorRow(title: "Tile colour", noneLabel: "Glass", defaultColor: Color(white: 0.25),
                         hex: Binding(get: { tile }, set: { tile = $0; dockPrefs.set(QuickCornerCatalog.tileColorKey, $0) }))
                RowDivider()
                ColorRow(title: "Icon colour", noneLabel: "White", defaultColor: .white,
                         hex: Binding(get: { glyph }, set: { glyph = $0; dockPrefs.set(QuickCornerCatalog.iconColorKey, $0) }))
            }
            .disabled(!enabled).opacity(enabled ? 1 : 0.5)
            ShortcutListEditor(list: QuickCornerCatalog.corner, what: "the fan",
                               footer: "Laid out like the fan: the top of the list is the top of the fan, the bottom sits in the corner. Drag to reorder, untick to hide, + to add any app, file or folder.")
                .disabled(!enabled).opacity(enabled ? 1 : 0.5)
            ShortcutAppsGroup()
            HStack {
                Spacer()
                Button("Reset look") {
                    for k in [QuickCornerCatalog.tileColorKey, QuickCornerCatalog.iconColorKey, QuickCornerCatalog.curveKey] { dockPrefs.set(k, nil) }
                    tile = nil; glyph = nil; curve = 1
                }
            }
        }
    }
}

struct AltTabSection: View {
    @State private var enabled: Bool = dockPrefs.value(AltTabSetting.enabled, default: true)
    @State private var key: String = dockPrefs.value(AltTabSetting.key, default: "option")
    @State private var size: String = dockPrefs.value(AltTabSetting.size, default: "medium")
    @State private var order: String = dockPrefs.value(AltTabSetting.order, default: "recent")

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PartOffBanner(part: .dock)
            SettingsGroup(footer: "Like Windows 11: hold the key and tap Tab to see every window (most recently used first, or the order you pick below). Tab or ← → to move, Shift-Tab to go back, let go to switch. Esc cancels; you can also point at a window and click it.") {
                ToggleRow(title: "Alt-Tab", detail: "Switch between windows, not just apps.",
                          isOn: Binding(get: { enabled }, set: { enabled = $0; dockPrefs.set(AltTabSetting.enabled, $0) }))
                RowDivider()
                PickerRow(title: "Shortcut", detail: key == "command" ? "Replaces the Mac's own ⌘ Tab app switcher." : "⌥ Option is the Mac's Alt key.",
                          selection: Binding(get: { key }, set: { key = $0; dockPrefs.set(AltTabSetting.key, $0) }),
                          options: [("option", "⌥ Tab"), ("command", "⌘ Tab")])
                .disabled(!enabled).opacity(enabled ? 1 : 0.45)
            }
            SettingsGroup {
                PickerRow(title: "Order", detail: order == "taskbar" ? "Apps in the order they sit on the taskbar."
                            : order == "name" ? "A to Z by app, then by window title." : "The window you used last comes first.",
                          selection: Binding(get: { order }, set: { order = $0; dockPrefs.set(AltTabSetting.order, $0) }),
                          options: [("recent", "Recently used"), ("taskbar", "Taskbar"), ("name", "A–Z")])
                RowDivider()
                PickerRow(title: "Preview size", selection: Binding(get: { size }, set: { size = $0; dockPrefs.set(AltTabSetting.size, $0) }),
                          options: [("small", "Small"), ("medium", "Medium"), ("large", "Large")])
                RowDivider()
                ToggleRow(title: "Include minimized windows", detail: "And windows of hidden apps, after the open ones.",
                          isOn: dockPrefs.binding(AltTabSetting.showMinimized, default: true))
            }
            .disabled(!enabled).opacity(enabled ? 1 : 0.45)
        }
    }
}

struct QuickAccessSection: View {
    @State private var gesture: Bool = dockPrefs.value(QuickCornerCatalog.gestureKey, default: true)
    @State private var shortcut: Shortcut? = Shortcut(stored: dockPrefs.value(QuickCornerCatalog.accessShortcutKey, default: ""))

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PartOffBanner(part: .dock)
            SettingsGroup(footer: "Swipe two fingers in from the right edge of the trackpad, where Notification Center's swipe was (BugOS turns that one off while this is on; Notification Center still opens from the clock). Your shortcuts slide in from the right side of the screen: slide down to pick one and lift to open it, or swipe back out to the edge to close them.") {
                ToggleRow(title: "Trackpad swipe", detail: "Two fingers in from the right edge of the trackpad.",
                          isOn: Binding(get: { gesture }, set: { gesture = $0; dockPrefs.set(QuickCornerCatalog.gestureKey, $0); SystemChanges.syncNotificationSwipe() }))
            }
            SettingsGroup(footer: "Opens Quick Access from anywhere. Then ↑ ↓ to pick, Return to open, Esc to close. None until you set one.") {
                ShortcutRow(title: "Keyboard shortcut", detail: "Press it again to close Quick Access.",
                            shortcuts: Binding(get: { shortcut.map { [$0] } ?? [] }, set: { list in
                                shortcut = list.last
                                dockPrefs.set(QuickCornerCatalog.accessShortcutKey, shortcut?.stored)
                            }), defaults: [], single: true, prefs: dockPrefs)
            }
            ShortcutListEditor(list: QuickCornerCatalog.access, what: "Quick Access",
                               footer: "Its own list, separate from the quick corner's: top to bottom as it appears. Drag to reorder, untick to hide, + to add any app, file or folder.")
            ShortcutAppsGroup()
        }
    }
}

/// Which apps the Music and AI shortcuts open (shared by the quick corner and Quick Access).
struct ShortcutAppsGroup: View {
    @State private var musicApp: String = dockPrefs.value(QuickCornerCatalog.musicAppKey, default: "com.spotify.client")
    @State private var aiApp: String = dockPrefs.value(QuickCornerCatalog.aiAppKey, default: "com.anthropic.claudefordesktop")
    @State private var browser: String = dockPrefs.value(QuickCornerCatalog.browserAppKey, default: "default")
    /// "Default" plus the browsers on this Mac (and the chosen one, even if it's gone).
    private var browserOptions: [(String, String)] {
        let installed = QuickCornerCatalog.browsers.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil || $0.id == browser
        }
        let def = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        return [("default", def.map { "Default (\($0))" } ?? "Default")] + installed.map { ($0.id, $0.name) }
    }
    var body: some View {
        SettingsGroup(footer: "The same in the quick corner and Quick Access.") {
            PickerRow(title: "Music shortcut opens", selection: Binding(get: { musicApp }, set: {
                musicApp = $0; dockPrefs.set(QuickCornerCatalog.musicAppKey, $0)
            }), options: [("com.spotify.client", "Spotify"), ("com.apple.Music", "Apple Music")])
            RowDivider()
            PickerRow(title: "AI shortcut opens", selection: Binding(get: { aiApp }, set: {
                aiApp = $0; dockPrefs.set(QuickCornerCatalog.aiAppKey, $0)
            }), options: QuickCornerCatalog.aiApps.map { ($0.id, $0.name) })
            RowDivider()
            MenuPickerRow(title: "Browser shortcut opens", selection: Binding(get: { browser }, set: {
                browser = $0; dockPrefs.set(QuickCornerCatalog.browserAppKey, $0)
            }), options: browserOptions)
        }
    }
}

/// One list of shortcuts (the quick corner's or Quick Access's): order, show/hide, add and remove apps.
/// Shown top first; stored bottom (nearest the corner) first.
struct ShortcutListEditor: View {
    let list: QuickCornerCatalog.List
    let what: String
    let footer: String
    @State private var apps: [String] = []
    @State private var shown: [QuickCornerCatalog.Entry] = []
    @State private var hidden: Set<String> = []

    private func load() {
        apps = dockPrefs.value(list.apps, default: [String]())
        hidden = Set(dockPrefs.value(list.hidden, default: list.defaultHidden))
        shown = QuickCornerCatalog.ordered(dockPrefs.value(list.order, default: nil as [String]?), apps: apps,
                                           defaultOrder: list.defaultOrder).reversed()
    }
    private func saveOrder() { dockPrefs.set(list.order, shown.reversed().map(\.id)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsGroup(footer: footer) {
                List {
                    ForEach(shown) { e in
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            if let path = e.appPath {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 20, height: 20)
                            } else {
                                Image(systemName: e.symbol).frame(width: 20).foregroundStyle(Color.accentColor)
                            }
                            Text(e.label).font(.system(size: 13))
                            Spacer()
                            if let path = e.appPath {
                                Button { remove(path) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                                    .buttonStyle(.plain).help("Remove \(e.label)")
                            }
                            Toggle("", isOn: Binding(get: { !hidden.contains(e.id) }, set: { show in
                                if show { hidden.remove(e.id) } else { hidden.insert(e.id) }
                                dockPrefs.set(list.hidden, Array(hidden))
                            }))
                            .labelsHidden()
                        }
                        .padding(.vertical, 3)
                    }
                    .onMove { from, to in shown.move(fromOffsets: from, toOffset: to); saveOrder() }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: CGFloat(shown.count) * 34 + 8)
            }
            HStack {
                Button { addApp() } label: { Label("Add…", systemImage: "plus") }
                Spacer()
                Button("Reset to default") {
                    for k in [list.order, list.hidden, list.apps] { dockPrefs.set(k, nil) }
                    load()
                }
            }
        }
        .onAppear(perform: load)
    }

    private func addApp() {
        // Apps, files or folders: whatever you pick opens from here.
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.treatsFilePackagesAsDirectories = false
        p.allowsMultipleSelection = true
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.message = "Choose apps, files or folders to add to \(what)."
        p.prompt = "Add"
        guard p.runModal() == .OK else { return }
        let new = p.urls.map(\.path).filter { !apps.contains($0) }
        guard !new.isEmpty else { return }
        apps += new
        dockPrefs.set(list.apps, apps)
        shown.insert(contentsOf: new.map(QuickCornerCatalog.appEntry), at: 0)   // new ones on top
        saveOrder()
    }

    private func remove(_ path: String) {
        apps.removeAll { $0 == path }
        shown.removeAll { $0.appPath == path }
        dockPrefs.set(list.apps, apps)
        saveOrder()
    }
}

struct ExplorerSection: View {
    @State private var opensFolders = SystemChanges.explorerOpensFolders
    @State private var start: String = explorerPrefs.value(ExplorerSetting.startLocation, default: "home:")
    @State private var sidePane: String = explorerPrefs.value("sidePane", default: "none")
    @State private var viewMode: String = ExplorerSection.defaultMode
    @State private var shortcut: Shortcut? = ExplorerSection.currentShortcut
    @State private var theme: String = explorerPrefs.value(ExplorerSetting.theme, default: "windows")
    @State private var appearance: String = explorerPrefs.value(ExplorerSetting.appearance, default: "system")
    @State private var iconStyle: String = explorerPrefs.value(ExplorerSetting.iconStyle, default: "auto")
    @State private var glassTint: String? = explorerPrefs.value(ExplorerSetting.glassTint, default: nil as String?)
    @State private var tintStrength: Double = explorerPrefs.value(ExplorerSetting.glassTintStrength, default: 0.2)
    @State private var navHidden: Set<String> = Set(explorerPrefs.value(ExplorerSetting.navHidden, default: [String]()))
    @State private var navPane: Bool = explorerPrefs.value("showNavPane", default: true)
    @State private var fileIcons: String = explorerPrefs.value(ExplorerSetting.fileIcons, default: "windows")
    @State private var navOrder: [String] = ExplorerSetting.orderedNavSections(explorerPrefs.value(ExplorerSetting.navOrder, default: nil as [String]?)).map(\.id)

    static var currentShortcut: Shortcut? {
        guard let s: String = explorerPrefs.value(ExplorerSetting.newWindowShortcut, default: nil as String?) else {
            return ExplorerSetting.defaultNewWindowShortcut
        }
        return Shortcut(stored: s)
    }
    /// File Explorer keeps its default folder view as JSON ({"mode": …, "sort": …, …}).
    static var defaultMode: String {
        guard let d: Data = explorerPrefs.value("defaultView", default: nil as Data?),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "details" }
        return o["mode"] as? String ?? "details"
    }
    static func setDefaultMode(_ m: String) {
        var o: [String: Any] = ["mode": "details", "sort": "name", "ascending": true, "group": "none"]
        if let d: Data = explorerPrefs.value("defaultView", default: nil as Data?),
           let old = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { o.merge(old) { _, b in b } }
        o["mode"] = m
        explorerPrefs.set("defaultView", try? JSONSerialization.data(withJSONObject: o))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PartOffBanner(part: .explorer)
            Text("Look").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ForEach([("windows", "Windows 11", "Solid, crisp surfaces"),
                         ("mica", "Mica", "Your wallpaper's tint in the frame"),
                         ("glass", "Liquid Glass", "The whole window is glass")], id: \.0) { t in
                    ThemeCard(id: t.0, title: t.1, detail: t.2, selected: theme == t.0) {
                        theme = t.0; explorerPrefs.set(ExplorerSetting.theme, t.0)
                    }
                }
            }
            SettingsGroup {
                PickerRow(title: "Appearance", selection: Binding(get: { appearance }, set: {
                    appearance = $0; explorerPrefs.set(ExplorerSetting.appearance, $0)
                }), options: [("system", "Auto"), ("light", "Light"), ("dark", "Dark")])
                RowDivider()
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("App icon").font(.system(size: 13))
                        Text("On the taskbar, the Dock and ⌘-Tab. Auto matches the appearance.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    ForEach([("auto", "Auto"), ("light", "Light"), ("dark", "Dark")], id: \.0) { o in
                        IconChoice(label: o.1, dark: o.0 == "dark" ? true : o.0 == "light" ? false : nil,
                                   selected: iconStyle == o.0) {
                            iconStyle = o.0; explorerPrefs.set(ExplorerSetting.iconStyle, o.0)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                RowDivider()
                Group {
                    ColorRow(title: "Glass tint", detail: "A wash of colour over Mica or Liquid Glass.", noneLabel: "No tint",
                             hex: Binding(get: { glassTint }, set: { glassTint = $0; explorerPrefs.set(ExplorerSetting.glassTint, $0) }))
                    RowDivider()
                    SliderRow(title: "Tint strength", value: Binding(get: { tintStrength }, set: {
                        tintStrength = $0; explorerPrefs.set(ExplorerSetting.glassTintStrength, $0)
                    }), range: 0.05...0.6, format: { "\(Int(($0 * 100).rounded()))%" })
                    .disabled(glassTint == nil).opacity(glassTint == nil ? 0.45 : 1)
                }
                .disabled(theme == "windows").opacity(theme == "windows" ? 0.45 : 1)
            }
            Text("Folders").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            SettingsGroup(footer: "Folders still open in Finder for a split second: File Explorer takes them over and closes Finder's window. The first time, macOS asks if BugOS may control Finder. Click OK.") {
                ToggleRow(title: "Open folders with File Explorer", detail: "Instead of Finder, everywhere on the Mac.",
                          isOn: Binding(get: { opensFolders }, set: { on in
                              opensFolders = on
                              SystemChanges.setExplorerOpensFolders(on) { opensFolders = SystemChanges.explorerOpensFolders }
                          }))
                RowDivider()
                ToggleRow(title: "Use File Explorer for Save and Open dialogs",
                          detail: "When an app asks where to save or what to open, File Explorer's window comes up instead of the Mac's.",
                          isOn: explorerPrefs.binding("bridgeEnabled", default: true))
                RowDivider()
                ShortcutRow(title: "New window shortcut", detail: "Opens a File Explorer window from anywhere, like Win+E.",
                            shortcuts: Binding(get: { shortcut.map { [$0] } ?? [] }, set: { list in
                                shortcut = list.last
                                explorerPrefs.set(ExplorerSetting.newWindowShortcut, shortcut?.stored ?? "")
                            }), defaults: [ExplorerSetting.defaultNewWindowShortcut], single: true, prefs: explorerPrefs)
            }
            Text("Windows").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            SettingsGroup {
                MenuPickerRow(title: "Open new windows to", selection: Binding(get: { start }, set: {
                    start = $0; explorerPrefs.set(ExplorerSetting.startLocation, $0)
                }), options: [("home:", "Home"), ("thismac:", "This Mac"),
                              (NSHomeDirectory() + "/Desktop", "Desktop"), (NSHomeDirectory() + "/Downloads", "Downloads"),
                              (NSHomeDirectory() + "/Documents", "Documents")])
                RowDivider()
                ToggleRow(title: "Reopen my last tabs", detail: "The first window after starting up brings back the tabs you had open.",
                          isOn: explorerPrefs.binding(ExplorerSetting.restoreTabs, default: true))
                RowDivider()
                MenuPickerRow(title: "Default folder view", detail: "For folders you haven't set a view for yet.",
                              selection: Binding(get: { viewMode }, set: { viewMode = $0; Self.setDefaultMode($0) }),
                              options: [("extraLarge", "Extra large icons"), ("large", "Large icons"), ("medium", "Medium icons"),
                                        ("small", "Small icons"), ("list", "List"), ("details", "Details"),
                                        ("tiles", "Tiles"), ("content", "Content")])
            }
            Text("Show").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            SettingsGroup {
                PickerRow(title: "File icons", detail: "Windows: the icon of the app that opens the file. Mac: macOS's document icons.",
                          selection: Binding(get: { fileIcons }, set: { fileIcons = $0; explorerPrefs.set(ExplorerSetting.fileIcons, $0) }),
                          options: [("windows", "Windows"), ("mac", "Mac")])
                RowDivider()
                ToggleRow(title: "File name extensions", isOn: explorerPrefs.binding("showExtensions", default: true))
                RowDivider()
                ToggleRow(title: "Hidden items", detail: "Files and folders whose names start with a dot.",
                          isOn: explorerPrefs.binding("showHidden", default: false))
                RowDivider()
                ToggleRow(title: "Item check boxes", isOn: explorerPrefs.binding("itemCheckBoxes", default: false))

                RowDivider()
                PickerRow(title: "Right-hand pane", selection: Binding(get: { sidePane }, set: {
                    sidePane = $0; explorerPrefs.set("sidePane", $0)
                }), options: [("none", "None"), ("details", "Details"), ("preview", "Preview")])
            }
            Text("Navigation pane").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            SettingsGroup(footer: "Pick what's listed down the left of every window. Drag to reorder.") {
                ToggleRow(title: "Show the navigation pane", isOn: Binding(get: { navPane }, set: {
                    navPane = $0; explorerPrefs.set("showNavPane", $0)
                }))
                RowDivider()
                List {
                    ForEach(navOrder, id: \.self) { id in
                        let sec = ExplorerSetting.navSections.first { $0.id == id }!
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            Image(systemName: sec.symbol).frame(width: 20).foregroundStyle(Color.accentColor)
                            Text(sec.title).font(.system(size: 13))
                            Spacer()
                            Toggle("", isOn: Binding(get: { !navHidden.contains(id) }, set: { show in
                                if show { navHidden.remove(id) } else { navHidden.insert(id) }
                                explorerPrefs.set(ExplorerSetting.navHidden, Array(navHidden))
                            }))
                            .labelsHidden()
                        }
                        .padding(.vertical, 3)
                    }
                    .onMove { from, to in
                        navOrder.move(fromOffsets: from, toOffset: to)
                        explorerPrefs.set(ExplorerSetting.navOrder, navOrder)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: CGFloat(navOrder.count) * 34 + 8)
                .disabled(!navPane).opacity(navPane ? 1 : 0.45)
            }
            HStack {
                Spacer()
                Button("Open File Explorer") { Supervisor.shared.showExplorer() }.disabled(!Part.explorer.enabled)
            }
        }
    }
}

/// One File Explorer icon to pick (light, dark, or both halves for Auto).
struct IconChoice: View {
    let label: String
    let dark: Bool?
    let selected: Bool
    let action: () -> Void
    private static let explorerApp = parts.appendingPathComponent("File Explorer.app")
    private static let light = NSWorkspace.shared.icon(forFile: explorerApp.path)
    private static let darkIcon = NSImage(contentsOf: explorerApp.appendingPathComponent("Contents/Resources/AppIconDark.icns")) ?? light

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Group {
                    if let dark {
                        Image(nsImage: dark ? Self.darkIcon : Self.light).resizable()
                    } else {   // Auto: half light, half dark
                        ZStack {
                            Image(nsImage: Self.light).resizable()
                            Image(nsImage: Self.darkIcon).resizable().mask(alignment: .trailing) {
                                Rectangle().frame(width: 22)
                            }
                        }
                    }
                }
                .frame(width: 44, height: 44)
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                Text(label).font(.system(size: 11)).foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// A small drawing of File Explorer in each theme.
struct ThemeCard: View {
    let id: String
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                preview
                    .frame(height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1))
                HStack(spacing: 6) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 12.5, weight: .medium))
                        Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private var dark: Bool { scheme == .dark }
    private func grey(_ d: Double, _ l: Double, _ a: Double = 1) -> Color { Color(white: dark ? d : l).opacity(a) }

    @ViewBuilder private var preview: some View {
        let wall = LinearGradient(colors: [Color(red: 0.25, green: 0.45, blue: 0.95), Color(red: 0.75, green: 0.35, blue: 0.75)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        let (frame, bar, nav, body): (Double, Double, Double, Double) = {
            switch id {
            case "mica": return (0.55, 0.55, 0.35, 0.94)
            case "glass": return (0.25, 0.22, 0.08, 0.5)
            default: return (1, 1, 1, 1)
            }
        }()
        ZStack {
            wall
            ZStack(alignment: .topLeading) {
                if id == "windows" { grey(0.13, 0.90) } else { Rectangle().fill(.ultraThinMaterial).opacity(id == "glass" ? 0.7 : 1); grey(0.13, 0.90, frame * 0.3) }
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        Circle().fill(.red).frame(width: 5, height: 5)
                        Circle().fill(.yellow).frame(width: 5, height: 5)
                        Circle().fill(.green).frame(width: 5, height: 5)
                        RoundedRectangle(cornerRadius: 3).fill(grey(0.19, 0.975, bar)).frame(width: 40, height: 10).padding(.leading, 4)
                        Spacer()
                    }
                    .padding(.horizontal, 6).frame(height: 16)
                    grey(0.19, 0.975, bar).frame(height: 14)
                    HStack(spacing: 0) {
                        grey(0.15, 1, nav).frame(width: 34)
                        grey(0.15, 1, body).overlay(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(0..<4, id: \.self) { _ in
                                    HStack(spacing: 4) {
                                        RoundedRectangle(cornerRadius: 1).fill(Color.blue.opacity(0.8)).frame(width: 7, height: 6)
                                        RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.25)).frame(width: 46, height: 3)
                                    }
                                }
                            }
                            .padding(6)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(10)
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
    }
}

struct FeaturesSection: View {
    @State private var on: [Part: Bool] = Dictionary(uniqueKeysWithValues: Part.allCases.map { ($0, $0.enabled) })

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Use all of BugOS, or just the parts you want. A part that's off doesn't run at all, and what it changed on your Mac goes back.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SettingsGroup {
                FeatureRow(symbol: "dock.rectangle", title: "Taskbar",
                           detail: "The Windows 11-style bar along the bottom, with previews, music and the quick corner. Off puts the Mac Dock back.",
                           isOn: binding(.dock))
                RowDivider()
                FeatureRow(symbol: "folder", title: "File Explorer",
                           detail: "Windows-style folders, tabs and Save/Open dialogs. Off makes Finder open folders again.",
                           isOn: binding(.explorer))
                RowDivider()
                FeatureRow(symbol: "scribble.variable", title: "Squiggle",
                           detail: "Snips and screen recordings you can draw on. Off gives the screenshot shortcuts back to the Mac.",
                           isOn: binding(.squiggle))
            }
            if !on.values.contains(true) {
                Label("Everything's off: BugOS will quit when you close this page. Open it again any time to turn something back on.",
                      systemImage: "info.circle")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func binding(_ p: Part) -> Binding<Bool> {
        Binding(get: { on[p] ?? true }, set: { v in on[p] = v; Supervisor.shared.setEnabled(p, v) })
    }
}

struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).frame(width: 28).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

struct SquiggleSection: View {
    @State private var folder: String = squigglePrefs.value(SquiggleSetting.saveFolder, default: SquiggleSetting.defaultFolder.path)
    @State private var saved: [String: String] = squigglePrefs.value(SquiggleSetting.shortcuts, default: [String: String]())
    @State private var pen: String? = SquiggleSection.penHex
    @State private var penWidth: Double = squigglePrefs.value("penWidth", default: 4.0)

    /// Squiggle keeps its pen colour as an archived NSColor.
    static var penHex: String? {
        guard let d: Data = squigglePrefs.value("penColor", default: nil as Data?),
              let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: d) else { return nil }
        return BugOSColor.hex(c)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PartOffBanner(part: .squiggle)
            Text("Shortcuts").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            SettingsGroup(footer: "Click + and press the keys you want. ⌘, ⌥ or ⌃ is needed unless it's a function key (F1–F20; PrtSc is F13 on Windows keyboards). Click a shortcut to remove it.") {
                ForEach(Array(SquiggleShortcuts.actions.enumerated()), id: \.element.id) { i, a in
                    if i > 0 { RowDivider() }
                    ShortcutRow(title: a.title, detail: a.detail, shortcuts: binding(a), defaults: a.defaults,
                                single: false, prefs: squigglePrefs)
                }
            }
            HStack {
                Spacer()
                Button("Reset shortcuts") { saved = [:]; squigglePrefs.set(SquiggleSetting.shortcuts, nil) }
            }
            Text("Saving").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            SettingsGroup(footer: "Snips you save land here; recordings go in its Recordings folder. Every snip is also copied to the clipboard.") {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Save to").font(.system(size: 13))
                        Text(folder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Show") {
                        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(URL(fileURLWithPath: folder))
                    }
                    Button("Change…") { chooseFolder() }
                    if folder != SquiggleSetting.defaultFolder.path {
                        Button("Default") { folder = SquiggleSetting.defaultFolder.path; squigglePrefs.set(SquiggleSetting.saveFolder, nil) }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                RowDivider()
                ToggleRow(title: "Show the snip thumbnail", detail: "The little preview in the bottom-right after a snip. Click it to draw on the snip.",
                          isOn: squigglePrefs.binding(SquiggleSetting.showThumbnail, default: true))
            }
            Text("Drawing").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            SettingsGroup(footer: "What the pen starts with when you draw on a snip. Changing it in the editor changes this too.") {
                ColorRow(title: "Pen colour", noneLabel: "Red", defaultColor: Color(red: 1, green: 0.18, blue: 0.13), hex: Binding(get: { pen }, set: { h in
                    pen = h
                    let data = h.flatMap(BugOSColor.color(hex:)).flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
                    squigglePrefs.set("penColor", data)
                }))
                RowDivider()
                SliderRow(title: "Pen size", value: Binding(get: { penWidth }, set: {
                    penWidth = $0; squigglePrefs.set("penWidth", $0)
                }), range: 1...20, step: 1, format: { "\(Int($0))pt" })
            }
            HStack {
                Button("Snip or Record…") { squigglePrefs.command("snip") }
                Button("Draw on a Recording…") { squigglePrefs.command("openVideo") }
                Spacer()
            }
            .disabled(!Part.squiggle.enabled)
            Text("Recording").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            SettingsGroup {
                ToggleRow(title: "Record sound from the Mac", detail: "What you hear: apps, videos, calls.",
                          isOn: squigglePrefs.binding(SquiggleSetting.recordSystemAudio, default: true))
                RowDivider()
                ToggleRow(title: "Record the microphone", detail: "Your voice, mixed in. You can also switch this on the Record bar.",
                          isOn: squigglePrefs.binding(SquiggleSetting.recordMic, default: false))
            }
        }
    }

    private func binding(_ a: ShortcutAction) -> Binding<[Shortcut]> {
        Binding(get: { SquiggleShortcuts.resolve(saved)[a.id] ?? [] }, set: { list in
            saved[a.id] = SquiggleShortcuts.encode(list)
            squigglePrefs.set(SquiggleSetting.shortcuts, saved)
        })
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Save Here"
        p.directoryURL = URL(fileURLWithPath: folder)
        guard p.runModal() == .OK, let u = p.url else { return }
        folder = u.path
        squigglePrefs.set(SquiggleSetting.saveFolder, u.path)
    }
}

/// Shown at the top of a part's section while that part is turned off in Features.
struct PartOffBanner: View {
    let part: Part
    var body: some View {
        if !part.enabled {
            HStack(spacing: 10) {
                Image(systemName: "power").foregroundStyle(.orange)
                Text("This part is turned off. These settings apply once it's back on.").font(.system(size: 12))
                Spacer()
                Button("Turn On") { Supervisor.shared.setEnabled(part, true); PageModel.current?.refresh += 1 }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        }
    }
}

struct PickerRow: View {
    let title: String
    var detail: String? = nil
    @Binding var selection: String
    let options: [(String, String)]
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 16)
            Picker("", selection: $selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            // Segments as wide as their labels (fixed widths let long labels spill out of the row).
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

struct MenuPickerRow: View {
    let title: String
    var detail: String? = nil
    @Binding var selection: String
    let options: [(String, String)]
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 16)
            Picker("", selection: $selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.menu).labelsHidden().frame(width: 180)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// A colour picker row: the colour in use, a divider, then the choices (the default, swatches, any colour).
/// nil = the default (`defaultColor`; nil there means "no colour", drawn as a slashed circle).
struct ColorRow: View {
    let title: String
    var detail: String? = nil
    /// Tooltip / name for the default choice.
    var noneLabel = "Default"
    /// What the default looks like (nil: no colour at all).
    var defaultColor: Color? = nil
    @Binding var hex: String?

    private var current: Color? { hex.flatMap(BugOSColor.color(hex:)).map { Color(nsColor: $0) } ?? defaultColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            HStack(spacing: 8) {
                dot(current, size: 26).help(hex ?? noneLabel)
                Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 1, height: 22).padding(.horizontal, 2)
                Button { hex = nil } label: { ring(dot(defaultColor, size: 18), on: hex == nil) }
                    .buttonStyle(.plain).help(noneLabel)
                ForEach(BugOSColor.swatches, id: \.hex) { sw in
                    Button { hex = sw.hex } label: {
                        ring(dot(Color(nsColor: BugOSColor.color(hex: sw.hex)!), size: 18), on: hex?.uppercased() == sw.hex)
                    }
                    .buttonStyle(.plain).help(sw.name)
                }
                ColorPicker("", selection: Binding(get: { current ?? .white }, set: { hex = BugOSColor.hex(NSColor($0)) }),
                            supportsOpacity: false)
                    .labelsHidden().controlSize(.small).help("Any colour")
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder private func dot(_ c: Color?, size: CGFloat) -> some View {
        if let c {
            Circle().fill(c).frame(width: size, height: size).overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
        } else {   // no colour
            Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1.5).frame(width: size, height: size)
                .overlay(Rectangle().fill(Color.red.opacity(0.8)).frame(width: 1.5, height: size).rotationEffect(.degrees(45)))
        }
    }
    private func ring(_ v: some View, on: Bool) -> some View {
        v.padding(2).overlay(Circle().strokeBorder(on ? Color.primary : .clear, lineWidth: 1.5))
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.05
    let format: (Double) -> String
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 16)
            Slider(value: $value, in: range, step: step).frame(width: 220)
            Text(format(value)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// One action's shortcuts as chips (click to remove), + to record another, ↺ for the default.
struct ShortcutRow: View {
    let title: String
    var detail: String? = nil
    @Binding var shortcuts: [Shortcut]
    let defaults: [Shortcut]
    /// Only one shortcut: recording replaces it.
    let single: Bool
    let prefs: PartPrefs
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail { Text(hint ?? detail).font(.system(size: 11.5)).foregroundStyle(hint == nil ? .secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            ForEach(shortcuts, id: \.self) { k in
                Button { shortcuts.removeAll { $0 == k } } label: {
                    HStack(spacing: 4) {
                        Text(k.display).font(.system(size: 12, weight: .medium, design: .rounded))
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain).help("Remove \(k.display)")
            }
            if shortcuts.isEmpty && !recording {
                Text("None").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            Button {
                recording ? stop() : record()
            } label: {
                if recording {
                    Text("Press keys…").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor))
                } else {
                    Image(systemName: single ? "pencil" : "plus").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
                }
            }
            .buttonStyle(.borderless).help(single ? "Change shortcut" : "Add a shortcut")
            Button { shortcuts = defaults } label: {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 11)).frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless).help("Back to default").disabled(shortcuts == defaults).opacity(shortcuts == defaults ? 0.3 : 1)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .onDisappear { stop() }
    }

    private func record() {
        recording = true
        hint = nil
        prefs.pauseShortcuts(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 && e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty { stop(); return nil }   // Esc
            guard let k = Shortcut(event: e) else {
                hint = "Add ⌘, ⌥ or ⌃ (or use a function key). Esc cancels."
                return nil
            }
            if single { shortcuts = [k] } else if !shortcuts.contains(k) { shortcuts.append(k) }
            hint = nil
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { prefs.pauseShortcuts(false) }
        recording = false
    }
}

/// The BugOS icon, draggable into System Settings' permission lists (they accept dropped apps).
struct DragIcon: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragIconView() }
    func updateNSView(_ v: NSView, context: Context) {}
}

final class DragIconView: NSView, NSDraggingSource {
    override func draw(_ r: NSRect) { NSApp.applicationIconImage.draw(in: bounds) }
    override func mouseDown(with e: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: NSApp.applicationIconImage)
        beginDraggingSession(with: [item], event: e, source: self)
    }
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

/// The page's window. `onClose` runs once it's gone.
@MainActor
final class PageController: NSObject, NSWindowDelegate {
    private var window: NSWindow!
    let model: PageModel
    private let onClose: () -> Void
    private var finished = false

    init(section: PageSection, onClose: @escaping () -> Void) {
        self.model = PageModel(section: section)
        self.onClose = onClose
        super.init()
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "BugOS"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PageView(model: model) { [weak self] in self?.window.close() })
        window.setContentSize(NSSize(width: 780, height: 560))
        window.center()
        window.delegate = self
    }

    func show(_ section: PageSection? = nil) {
        if let section { model.section = section }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ n: Notification) {
        guard !finished else { return }
        finished = true
        model.stop()
        let restart = model.newlyGranted
        DispatchQueue.main.async { [onClose] in
            if restart { for p in Part.allCases { Supervisor.shared.restart(p) } }
            onClose()
        }
    }
}
