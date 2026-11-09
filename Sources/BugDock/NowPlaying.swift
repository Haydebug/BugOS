import AppKit
import Combine
import SwiftUI

/// What's playing in Spotify or Apple Music, read through each app's public AppleScript
/// dictionary (no private MediaRemote). Only talks to a player that is already running.
struct NowPlayingInfo: Equatable {
    let bundleID: String
    let trackID: String
    let title: String
    let artist: String
    let artURL: String?     // Spotify gives an https URL; Music gives raw image data instead
}

/// Where the song is: position read at `at`, extrapolated between polls while playing.
struct PlaybackProgress: Equatable {
    let trackKey: String
    let position: Double    // seconds
    let duration: Double    // seconds
    let at: Date
    let playing: Bool

    private func elapsed(_ now: Date) -> Double { position + (playing ? now.timeIntervalSince(at) : 0) }

    func fraction(at now: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed(now) / duration))
    }

    func remaining(at now: Date) -> Double { max(0, duration - elapsed(now)) }
}

@MainActor
final class NowPlaying: ObservableObject {
    @Published private(set) var info: NowPlayingInfo?
    @Published private(set) var art: NSImage?
    @Published private(set) var progress: PlaybackProgress?
    /// Whether the current Spotify track is in Liked Songs (nil = unknown / not applicable).
    @Published private(set) var liked: Bool?
    private var likedCache: [String: Bool] = [:]
    private var authSub: AnyCancellable?

    static let players = ["com.spotify.client", "com.apple.Music"]

    private let queue = DispatchQueue(label: "com.bugos.dock.nowplaying", qos: .utility)
    private var timer: Timer?
    private var inFlight = false
    private var artKey: String?
    private var artCache: [String: NSImage] = [:]
    private var lastPlayer: String?
    /// While hovered, or for a few seconds after a pause started from the widget, keep showing a paused track.
    var hovering = false
    private var holdUntil = Date.distantPast
    private var keepPaused: Bool { hovering || Date() < holdUntil }

    var isPlaying: Bool { progress?.playing ?? false }

    enum Command: String { case previous = "previous track", playPause = "playpause", next = "next track" }

    func send(_ command: Command) {
        guard let id = info?.bundleID else { return }
        if command == .playPause && isPlaying { holdUntil = Date().addingTimeInterval(5) }
        queue.async { [weak self] in
            PlayerScripts.send(command.rawValue, to: id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.poll()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.poll() }
                }
            }
        }
    }

    /// A command for one particular player (the taskbar preview's buttons under Spotify or Music).
    func send(_ command: Command, to bundleID: String) {
        if command == .playPause && isPlaying && info?.bundleID == bundleID { holdUntil = Date().addingTimeInterval(5) }
        queue.async { [weak self] in
            PlayerScripts.send(command.rawValue, to: bundleID)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.poll()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.poll() }
                }
            }
        }
    }

    /// Whether this player is the one playing right now.
    func isPlaying(_ bundleID: String) -> Bool { info?.bundleID == bundleID && isPlaying }

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
        }
        // The BugOS page changed a setting: re-read it now.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.bugos.dock.settings"),
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
                self?.poll()
            }
        }
        poll()
        authSub = SpotifyAuth.shared.$isConnected.dropFirst().receive(on: RunLoop.main).sink { [weak self] connected in
            MainActor.assumeIsolated {
                if !connected { self?.likedCache.removeAll() }
                self?.refreshLiked()
            }
        }
    }

    // MARK: Liked Songs (Spotify Web API)

    /// The Spotify track URI the heart applies to; nil for local files, episodes, or other players.
    var likeableURI: String? {
        guard let info, info.bundleID == "com.spotify.client", info.trackID.hasPrefix("spotify:track:") else { return nil }
        return info.trackID
    }

    var canLike: Bool { likeableURI != nil && SpotifyAuth.shared.isConnected }

    func refreshLiked() {
        guard canLike, let uri = likeableURI else { liked = nil; return }
        if let cached = likedCache[uri] { liked = cached; return }
        liked = nil
        Task { [weak self] in
            let saved = await SpotifyLibrary.isSaved(uri)
            guard let self, self.likeableURI == uri, let saved else { return }
            self.likedCache[uri] = saved
            self.liked = saved
        }
    }

    func toggleLike() {
        guard canLike, let uri = likeableURI else { return }
        let target = !(liked ?? false)
        liked = target                      // optimistic
        likedCache[uri] = target
        Task { [weak self] in
            let ok = await SpotifyLibrary.setSaved(uri, target)
            guard let self, !ok else { return }
            self.likedCache[uri] = !target  // revert
            if self.likeableURI == uri { self.liked = !target }
        }
    }

    /// The BugOS page's "Show music on the taskbar" switch (on unless turned off).
    static var enabled: Bool { UserDefaults.standard.object(forKey: "showNowPlaying") as? Bool ?? true }

    func poll() {
        guard !inFlight else { return }
        guard Self.enabled else { setInfo(nil); progress = nil; return }   // off: no widget, no player polling
        let running = Self.players.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        guard !running.isEmpty else { setInfo(nil); progress = nil; return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        inFlight = true
        queue.async { [weak self] in
            let playing = running.compactMap { PlayerScripts.nowPlaying($0) }
            let polledAt = Date()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inFlight = false
                    let active = playing.filter(\.isPlaying)
                    var pick = active.first { $0.info.bundleID == front }
                        ?? active.first { $0.info.bundleID == self.lastPlayer }
                        ?? active.first
                    // Nothing playing: keep showing the paused track (it stays put),
                    // preferring the player that was already on screen.
                    if pick == nil {
                        pick = playing.first { $0.info.bundleID == self.info?.bundleID }
                            ?? playing.first { $0.info.bundleID == self.lastPlayer }
                            ?? playing.first { $0.info.bundleID == front }
                            ?? playing.first
                    }
                    self.setInfo(pick?.info)
                    self.progress = pick.map {
                        PlaybackProgress(trackKey: $0.info.bundleID + "|" + $0.info.trackID,
                                         position: $0.position, duration: $0.duration, at: polledAt,
                                         playing: $0.isPlaying)
                    }
                }
            }
        }
    }

    private func setInfo(_ new: NowPlayingInfo?) {
        if new != info { info = new }
        guard let new else { liked = nil; return }
        lastPlayer = new.bundleID
        let key = new.bundleID + "|" + new.trackID
        guard key != artKey else { return }
        artKey = key
        refreshLiked()
        if let cached = artCache[key] { art = cached; return }
        art = nil
        if let s = new.artURL, let url = URL(string: s), url.scheme == "https" {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                let img = data.flatMap { NSImage(data: $0) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.storeArt(img, key: key) }
                }
            }.resume()
        } else if new.bundleID == "com.apple.Music" {
            queue.async {
                let img = PlayerScripts.musicArtwork().flatMap { NSImage(data: $0) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.storeArt(img, key: key) }
                }
            }
        }
    }

    private func storeArt(_ img: NSImage?, key: String) {
        guard let img else { return }
        if artCache.count > 50 { artCache.removeAll() }
        artCache[key] = img
        if artKey == key { art = img }
    }

    func openPlayer() {
        guard let id = info?.bundleID,
              let url = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.bundleURL else { return }
        WindowActions.open(url)   // like a Dock click: brings it forward, reopens its window if closed
    }
}

/// AppleScript calls. Every script checks `is running` first, so it can never launch a player.
/// Only ever run on NowPlaying's serial queue (one script at a time).
enum PlayerScripts {
    private static var compiled: [String: NSAppleScript] = [:]
    private static var denied = Set<String>()   // Automation permission refused: stop asking

    private static let sources: [String: String] = [
        "com.spotify.client": """
        if application id "com.spotify.client" is running then
          with timeout of 2 seconds
            tell application id "com.spotify.client"
              if player state is stopped then return ""
              set t to current track
              return {id of t, name of t, artist of t, artwork url of t, player position, (duration of t) / 1000, player state is playing}
            end tell
          end timeout
        end if
        return ""
        """,
        "com.apple.Music": """
        if application id "com.apple.Music" is running then
          with timeout of 2 seconds
            tell application id "com.apple.Music"
              if player state is stopped then return ""
              set t to current track
              return {persistent ID of t, name of t, artist of t, "", player position, duration of t, player state is playing}
            end tell
          end timeout
        end if
        return ""
        """,
        "musicArt": """
        if application id "com.apple.Music" is running then
          with timeout of 2 seconds
            tell application id "com.apple.Music"
              return raw data of artwork 1 of current track
            end tell
          end timeout
        end if
        """,
    ]

    private static func run(_ key: String, deniedKey: String) -> NSAppleEventDescriptor? {
        guard !denied.contains(deniedKey), let src = sources[key] else { return nil }
        let script = compiled[key] ?? NSAppleScript(source: src)
        compiled[key] = script
        var err: NSDictionary?
        let result = script?.executeAndReturnError(&err)
        if let code = err?[NSAppleScript.errorNumber] as? Int, code == -1743 { denied.insert(deniedKey) }
        return err == nil ? result : nil
    }

    struct Reading { let info: NowPlayingInfo; let position: Double; let duration: Double; let isPlaying: Bool }

    /// Stopped (or not running) returns "" from the script, which isn't a 7-item list.
    static func nowPlaying(_ bundleID: String) -> Reading? {
        guard let d = run(bundleID, deniedKey: bundleID), d.numberOfItems >= 7 else { return nil }
        func str(_ i: Int) -> String { d.atIndex(i)?.stringValue ?? "" }
        func num(_ i: Int) -> Double { d.atIndex(i)?.doubleValue ?? 0 }
        let title = str(2)
        guard !title.isEmpty else { return nil }
        let art = str(4)
        let info = NowPlayingInfo(bundleID: bundleID, trackID: str(1), title: title, artist: str(3),
                                  artURL: art.isEmpty ? nil : art)
        return Reading(info: info, position: num(5), duration: num(6), isPlaying: d.atIndex(7)?.booleanValue ?? false)
    }

    /// Transport command to a player that is already running (the script re-checks).
    static func send(_ command: String, to bundleID: String) {
        guard !denied.contains(bundleID), sources[bundleID] != nil else { return }
        let key = bundleID + "|" + command
        let src = """
        if application id "\(bundleID)" is running then
          with timeout of 2 seconds
            tell application id "\(bundleID)" to \(command)
          end timeout
        end if
        """
        let script = compiled[key] ?? NSAppleScript(source: src)
        compiled[key] = script
        var err: NSDictionary?
        script?.executeAndReturnError(&err)
        if let code = err?[NSAppleScript.errorNumber] as? Int, code == -1743 { denied.insert(bundleID) }
    }

    static func musicArtwork() -> Data? {
        guard let d = run("musicArt", deniedKey: "com.apple.Music")?.data, !d.isEmpty else { return nil }
        return d
    }
}

/// Album art + title/artist on the left of the bar. Hidden when nothing is playing.
struct NowPlayingWidget: View {
    @ObservedObject var model: NowPlaying
    @ObservedObject private var auth = SpotifyAuth.shared
    @State private var hovering = false

    var body: some View {
        if let info = model.info {
            HStack(spacing: 4) {
                // Cover + text opens the player; the transport controls are separate buttons, so they never open it.
                Button { model.openPlayer() } label: {
                    HStack(spacing: 8) {
                        cover(info)
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
                            let p = model.progress
                            VStack(alignment: .leading, spacing: 0) {
                                Text(info.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text(info.artist)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.72))
                                ProgressLine(fraction: p?.fraction(at: ctx.date) ?? 0)
                                    .opacity(p?.duration ?? 0 > 0 ? 1 : 0)
                                    .padding(.top, 3)
                            }
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())

                if hovering {
                    HStack(spacing: 0) {
                        if auth.isConnected && model.likeableURI != nil {
                            TransportButton(symbol: model.liked == true ? "heart.fill" : "heart",
                                            tint: model.liked == true ? Color(red: 0x1D / 255, green: 0xB9 / 255, blue: 0x54 / 255) : .white) {
                                model.toggleLike()
                            }
                        }
                        TransportButton(symbol: "backward.fill") { model.send(.previous) }
                        TransportButton(symbol: model.isPlaying ? "pause.fill" : "play.fill") { model.send(.playPause) }
                        TransportButton(symbol: "forward.fill") { model.send(.next) }
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: 220, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(hovering ? 0.11 : 0)))
            .onHover { h in
                hovering = h
                model.hovering = h
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .transition(.opacity)
        }
    }

    static func remaining(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "-%d:%02d", s / 60, s % 60)
    }

    @ViewBuilder private func cover(_ info: NowPlayingInfo) -> some View {
        if let art = model.art {
            Image(nsImage: art).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
        } else if let url = NSRunningApplication.runningApplications(withBundleIdentifier: info.bundleID).first?.bundleURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: "music.note").resizable().scaledToFit().padding(6).foregroundStyle(.white)
        }
    }
}

/// Thin white song-progress bar: elapsed fill on a faint track.
struct ProgressLine: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(Color.white.opacity(0.9))
                    .frame(width: max(2, geo.size.width * fraction))
            }
        }
        .frame(height: 2)
        .frame(maxWidth: .infinity)
    }
}

/// Previous / play-pause / next on the Now Playing widget.
struct TransportButton: View {
    let symbol: String
    var tint: Color = .white
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(hovering ? 0.15 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
    }
}
