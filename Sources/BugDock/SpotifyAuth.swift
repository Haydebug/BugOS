import AppKit
import CryptoKit
import Foundation
import Network
import Security

/// Spotify Web API sign-in with Authorization Code + PKCE (no client secret).
/// Refresh token lives in the Keychain; the access token only in memory.
/// Docs: https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow
@MainActor
final class SpotifyAuth: ObservableObject {
    static let shared = SpotifyAuth()

    /// No client id is built into the app. "Connect Spotify" appears once one is set:
    ///   defaults write com.bugos.dock spotifyClientID <your Spotify app's client id>
    static var clientID: String { UserDefaults.standard.string(forKey: "spotifyClientID") ?? "" }
    static var isAvailable: Bool { !clientID.isEmpty }
    static let port: UInt16 = 43821
    static let redirectURI = "http://127.0.0.1:43821/callback"   // loopback literal, http allowed by Spotify
    static let scopes = "user-library-read user-library-modify"

    /// Also saved as "spotifyConnected" so the BugOS page can show it.
    @Published private(set) var isConnected: Bool { didSet { UserDefaults.standard.set(isConnected, forKey: "spotifyConnected") } }

    private var accessToken: String?
    private var expiresAt = Date.distantPast
    private var refreshTask: Task<String?, Never>?
    private var listener: NWListener?
    private var pending: (verifier: String, state: String)?
    private var timeout: DispatchWorkItem?

    private init() {
        isConnected = SpotifyKeychain.read() != nil
        UserDefaults.standard.set(isConnected, forKey: "spotifyConnected")   // didSet doesn't run in init
    }

    // MARK: Connect / disconnect

    func connect() {
        stopListening()
        let verifier = PKCE.verifier()
        let state = PKCE.verifier(length: 32)
        guard startListening() else { return }
        pending = (verifier, state)
        if let url = Self.authorizeURL(challenge: PKCE.challenge(for: verifier), state: state) {
            NSWorkspace.shared.open(url)
        }
        let work = DispatchWorkItem { [weak self] in self?.stopListening() }   // give up after 3 minutes
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: work)
    }

    func disconnect() {
        stopListening()
        SpotifyKeychain.delete()
        accessToken = nil
        expiresAt = .distantPast
        isConnected = false
    }

    static func authorizeURL(challenge: String, state: String) -> URL? {
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")
        c?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
        ]
        return c?.url
    }

    // MARK: One-shot loopback listener on 127.0.0.1:43821

    private func startListening() -> Bool {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
        guard let l = try? NWListener(using: params) else {
            NSLog("BugDock: couldn't open the Spotify callback port \(Self.port)")
            return false
        }
        l.newConnectionHandler = { [weak self] conn in
            MainActor.assumeIsolated { self?.handle(conn) }
        }
        l.start(queue: .main)
        listener = l
        return true
    }

    private func stopListening() {
        timeout?.cancel()
        timeout = nil
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            MainActor.assumeIsolated {
                guard let self else { conn.cancel(); return }
                let firstLine = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
                let parts = firstLine.split(separator: " ")
                let target = parts.count >= 2 ? String(parts[1]) : ""
                let comps = URLComponents(string: "http://127.0.0.1" + target)
                guard comps?.path == "/callback" else {
                    Self.respond(conn, status: "404 Not Found", body: "Not found")
                    return
                }
                let q = Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
                guard let pending = self.pending, q["state"] == pending.state else {
                    Self.respond(conn, status: "400 Bad Request", body: "This sign-in link has expired. Try Connect Spotify again from BugDock.")
                    return
                }
                if let code = q["code"], !code.isEmpty {
                    Self.respond(conn, status: "200 OK", body: "BugDock is connected to Spotify. You can close this tab.")
                    self.pending = nil
                    self.stopListening()
                    Task { await self.exchange(code: code, verifier: pending.verifier) }
                } else {
                    Self.respond(conn, status: "200 OK", body: "Spotify sign-in was cancelled. You can close this tab.")
                    self.pending = nil
                    self.stopListening()
                }
            }
        }
    }

    private static func respond(_ conn: NWConnection, status: String, body: String) {
        let html = "<!doctype html><meta charset=utf-8><title>BugDock</title><body style=\"font:16px -apple-system,sans-serif;padding:40px\">\(body)</body>"
        let bytes = Array(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + Data(bytes), completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: Tokens

    private func exchange(code: String, verifier: String) async {
        let json = await Self.tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": Self.clientID,
            "code_verifier": verifier,
        ])
        guard let json, store(json) else { NSLog("BugDock: Spotify token exchange failed"); return }
        isConnected = true
    }

    /// A usable access token, refreshing it if needed. nil = not connected (or refresh failed).
    func validToken(forceRefresh: Bool = false) async -> String? {
        if !forceRefresh, let t = accessToken, expiresAt > Date().addingTimeInterval(30) { return t }
        if let running = refreshTask { return await running.value }
        let task = Task<String?, Never> { await self.refresh() }
        refreshTask = task
        let t = await task.value
        refreshTask = nil
        return t
    }

    private func refresh() async -> String? {
        guard let rt = SpotifyKeychain.read() else { isConnected = false; return nil }
        let (json, status) = await Self.tokenRequestWithStatus([
            "grant_type": "refresh_token",
            "refresh_token": rt,
            "client_id": Self.clientID,
        ])
        if status == 400 || status == 401 {           // revoked or invalid: sign out cleanly
            disconnect()
            return nil
        }
        guard let json, store(json) else { return nil }
        return accessToken
    }

    /// Save tokens from a token response. Spotify may or may not rotate the refresh token.
    private func store(_ json: [String: Any]) -> Bool {
        guard let at = json["access_token"] as? String else { return false }
        accessToken = at
        expiresAt = Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3600)
        if let rt = json["refresh_token"] as? String, !rt.isEmpty { SpotifyKeychain.write(rt) }
        return SpotifyKeychain.read() != nil
    }

    private static func tokenRequest(_ form: [String: String]) async -> [String: Any]? {
        await tokenRequestWithStatus(form).0
    }

    private static func tokenRequestWithStatus(_ form: [String: String]) async -> ([String: Any]?, Int) {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = c.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .data(using: .utf8)
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (nil, 0) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (status == 200 ? json : nil, status)
    }

    // MARK: Web API

    /// Calls the Web API. Retries once with a fresh token on 401. Returns (body, status); status 0 = network/no token.
    func api(_ method: String, _ path: String, query: [URLQueryItem]) async -> (Data?, Int) {
        for attempt in 0..<2 {
            guard let token = await validToken(forceRefresh: attempt == 1) else { return (nil, 0) }
            var c = URLComponents(string: "https://api.spotify.com/v1" + path)
            c?.queryItems = query
            guard let url = c?.url else { return (nil, 0) }
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (nil, 0) }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 { continue }
            return (data, status)
        }
        return (nil, 401)
    }
}

/// Liked Songs through the library endpoints:
/// https://developer.spotify.com/documentation/web-api/reference/check-library-contains
/// https://developer.spotify.com/documentation/web-api/reference/save-library-items
/// https://developer.spotify.com/documentation/web-api/reference/remove-library-items
enum SpotifyLibrary {
    /// true/false = saved or not; nil = couldn't tell (not connected, rate-limited, error).
    @MainActor
    static func isSaved(_ uri: String) async -> Bool? {
        let (data, status) = await SpotifyAuth.shared.api("GET", "/me/library/contains", query: [URLQueryItem(name: "uris", value: uri)])
        guard status == 200, let data, let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Bool] else { return nil }
        return arr.first
    }

    /// Save (true) or remove (false). Returns whether Spotify accepted it.
    @MainActor
    static func setSaved(_ uri: String, _ saved: Bool) async -> Bool {
        let (_, status) = await SpotifyAuth.shared.api(saved ? "PUT" : "DELETE", "/me/library", query: [URLQueryItem(name: "uris", value: uri)])
        return (200..<300).contains(status)
    }
}

enum PKCE {
    private static let charset = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func verifier(length: Int = 64) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The Spotify refresh token, in an owner-only (0600) file in Application Support, cached in memory.
/// Not the Keychain: BugDock is self-signed, so the login Keychain ties "Always Allow" to each exact
/// build and re-prompted for the password after every rebuild and token refresh. The token only
/// grants Liked Songs access and can be revoked from the Spotify account page.
/// (Name kept so call sites don't change.)
@MainActor
enum SpotifyKeychain {
    private static var cached: String??   // nil = not loaded yet; .some(nil) = no token

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BugDock", isDirectory: true)
        return dir.appendingPathComponent("spotify-refresh-token")
    }

    static func read() -> String? {
        if let cached { return cached }
        let token = (try? String(contentsOf: fileURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (token?.isEmpty == false) ? token : nil
        cached = .some(value)
        return value
    }

    static func write(_ token: String) {
        cached = .some(token)
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard fm.createFile(atPath: fileURL.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
            NSLog("BugDock: couldn't save the Spotify login")
            return
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func delete() {
        cached = .some(nil)
        try? FileManager.default.removeItem(at: fileURL)
    }
}
