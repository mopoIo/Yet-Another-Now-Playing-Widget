import AppKit
import Network
import CryptoKit

struct SessionDto: Codable {
    var id = ""
    var app = ""
    var title: String?
    var artist: String?
    var album: String?
    var status = "Unknown"
    var isCurrent = false
    var thumbnail: String?
    var position = 0.0
    var duration = 0.0
}

struct StatePayload: Codable {
    var type = "state"
    var sessions: [SessionDto] = []
    var currentId: String?
    var latchedId: String?
    var latchedName: String?
    var showApp = false
    var hidePaused = false
    var layout = "classic"
    var launchOnStartup = false
    var accent: String?
    var active: SessionDto?
    var ts: Int64 = 0
}

struct Settings: Codable {
    var latchedId: String?
    var showApp = false
    var hidePaused = false
    var layout = "classic"
    var accent: String?
}

final class Server {
    let port: UInt16
    private let queue = DispatchQueue(label: "np.server")
    private let pollQueue = DispatchQueue(label: "np.poll")
    private let lock = NSLock()

    private var clients: [ObjectIdentifier: Conn] = [:]
    private var lastState: StatePayload?
    private var lastSignature = ""
    private var lastSend = Date.distantPast

    // null = follow whatever's playing, otherwise an app id ("spotify"/"music") to lock onto
    private var latchedId: String?
    private var showApp = false
    private var hidePaused = false
    private var layout = "classic"
    private var accent = ""

    private var artSig = ""
    private var artData: String?

    private let settingsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/nowplaying/settings.json")

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []
        return e
    }()

    init(port: UInt16) { self.port = port }

    func start() throws {
        loadSettings()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback        // localhost only
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            Conn(connection: c, server: self).start(on: self.queue)
        }
        listener.start(queue: queue)

        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.refresh(force: false) }
        timer.resume()
        self.pollTimer = timer
        pollQueue.async { [weak self] in self?.refresh(force: true) }
    }
    private var pollTimer: DispatchSourceTimer?

    private func refresh(force: Bool) {
        let sessions = readSessions()
        let state = buildState(sessions)
        let sig = signature(state)

        lock.lock()
        let changed = sig != lastSignature
        let heartbeat = Date().timeIntervalSince(lastSend) >= 4
        lastState = state
        lastSignature = sig
        lock.unlock()

        if changed || heartbeat || force { send(state) }
    }

    private func buildState(_ sessions: [SessionDto]) -> StatePayload {
        var p = StatePayload()
        p.sessions = sessions
        p.currentId = sessions.first(where: { $0.status == "Playing" })?.id
        for i in p.sessions.indices { p.sessions[i].isCurrent = p.sessions[i].id == p.currentId }

        lock.lock()
        p.latchedId = latchedId; p.showApp = showApp; p.hidePaused = hidePaused
        p.layout = layout; p.accent = accent.isEmpty ? nil : accent
        let latched = latchedId
        lock.unlock()

        p.launchOnStartup = startupEnabled()
        p.active = selectActive(p.sessions, p.currentId, latched)
        p.latchedName = latchName(p.sessions, latched)
        return p
    }

    // when latched, return nil if that app is gone so the overlay waits for it
    // instead of grabbing whatever took over
    private func selectActive(_ sessions: [SessionDto], _ currentId: String?, _ latchedId: String?) -> SessionDto? {
        if let l = latchedId, !l.isEmpty { return sessions.first(where: { $0.id == l }) }
        return sessions.first(where: { $0.id == currentId })
            ?? sessions.first(where: { $0.status == "Playing" })
            ?? sessions.first
    }

    private func latchName(_ sessions: [SessionDto], _ latchedId: String?) -> String? {
        guard let l = latchedId, !l.isEmpty else { return nil }
        return sessions.first(where: { $0.id == l })?.app ?? pretty(l)
    }

    private func pretty(_ id: String) -> String {
        switch id { case "spotify": return "Spotify"; case "music": return "Apple Music"; default: return id }
    }

    // asks System Events which apps are up first, so we never accidentally launch one
    private func readSessions() -> [SessionDto] {
        let us = "\u{1f}", rs = "\u{1e}"   // unit / record separators, won't collide with track text
        let script = """
        set out to ""
        set us to (ASCII character 31)
        set rs to (ASCII character 30)
        tell application "System Events" to set procs to name of every process
        if procs contains "Spotify" then
          try
            tell application "Spotify"
              if player state is not stopped then
                set t to current track
                set out to out & "spotify" & us & "Spotify" & us & (name of t) & us & (artist of t) & us & (album of t) & us & (player state as text) & us & (player position as text) & us & ((duration of t) / 1000 as text) & us & (artwork url of t) & rs
              end if
            end tell
          end try
        end if
        if procs contains "Music" then
          try
            tell application "Music"
              if player state is not stopped then
                set t to current track
                set out to out & "music" & us & "Apple Music" & us & (name of t) & us & (artist of t) & us & (album of t) & us & (player state as text) & us & (player position as text) & us & (duration of t as text) & us & "" & rs
              end if
            end tell
          end try
        end if
        return out
        """
        guard let raw = runScript(script), !raw.isEmpty else { return [] }

        var out: [SessionDto] = []
        for rec in raw.components(separatedBy: rs) where !rec.isEmpty {
            let f = rec.components(separatedBy: us)
            if f.count < 9 { continue }
            var s = SessionDto()
            s.id = f[0]; s.app = f[1]
            s.title = nilIfEmpty(f[2]); s.artist = nilIfEmpty(f[3]); s.album = nilIfEmpty(f[4])
            s.status = mapStatus(f[5])
            s.position = Double(f[6]) ?? 0
            s.duration = Double(f[7]) ?? 0
            s.thumbnail = s.id == "music" ? musicArt(sig: (s.title ?? "") + (s.artist ?? "")) : nilIfEmpty(f[8])
            out.append(s)
        }
        return out
    }

    // Apple Music has no artwork url, so dump the raw bytes to a temp file and inline them
    private func musicArt(sig: String) -> String? {
        lock.lock(); if sig == artSig { let v = artData; lock.unlock(); return v }; lock.unlock()

        let file = NSTemporaryDirectory() + "np-music-art"
        try? FileManager.default.removeItem(atPath: file)   // else a failed read serves the previous track's art
        let script = """
        tell application "Music"
          try
            set d to (get raw data of artwork 1 of current track)
            set f to open for access (POSIX file "\(file)") with write permission
            set eof f to 0
            write d to f
            close access f
          end try
        end tell
        """
        _ = runScript(script)
        var data: String?
        if let bytes = try? Data(contentsOf: URL(fileURLWithPath: file)), !bytes.isEmpty {
            data = "data:\(mimeOf(bytes));base64,\(bytes.base64EncodedString())"
        }
        // streamed art loads a beat after the track starts, so don't cache an empty
        // result - keep retrying each poll until it shows up
        if data != nil { lock.lock(); artSig = sig; artData = data; lock.unlock() }
        return data
    }

    private func runScript(_ source: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        return s.hasSuffix("\n") ? String(s.dropLast()) : s
    }

    private func mapStatus(_ s: String) -> String {
        let l = s.lowercased()
        if l.contains("play") || l.contains("forward") || l.contains("rewind") { return "Playing" }
        if l.contains("pause") { return "Paused" }
        return "Stopped"
    }

    func handleMessage(_ msg: String) {
        guard let data = msg.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "latch":      applyLatch(obj["id"] as? String)
        case "showApp":    lock.lock(); showApp = (obj["value"] as? Bool) ?? false; lock.unlock(); rebroadcast { $0.showApp = self.showApp }
        case "hidePaused": lock.lock(); hidePaused = (obj["value"] as? Bool) ?? false; lock.unlock(); rebroadcast { $0.hidePaused = self.hidePaused }
        case "setLayout":  lock.lock(); layout = (obj["value"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "classic"; lock.unlock(); rebroadcast { $0.layout = self.layout }
        case "setAccent":  lock.lock(); accent = normalizeHex(obj["value"] as? String); lock.unlock(); rebroadcast { $0.accent = self.accent.isEmpty ? nil : self.accent }
        case "launchOnStartup": setStartup((obj["value"] as? Bool) ?? false); rebroadcast { $0.launchOnStartup = self.startupEnabled() }
        default: break
        }
    }

    private func applyLatch(_ id: String?) {
        lock.lock(); latchedId = (id?.isEmpty ?? true) ? nil : id; let l = latchedId; lock.unlock()
        rebroadcast {
            $0.latchedId = l
            $0.active = self.selectActive($0.sessions, $0.currentId, l)
            $0.latchedName = self.latchName($0.sessions, l)
        }
    }

    private func rebroadcast(_ mutate: (inout StatePayload) -> Void) {
        saveSettings()
        lock.lock()
        guard var snap = lastState else { lock.unlock(); return }
        mutate(&snap)
        lastState = snap
        lastSignature = signature(snap)
        lock.unlock()
        send(snap)
    }

    private func send(_ state: StatePayload) {
        var s = state
        s.ts = Int64(Date().timeIntervalSince1970 * 1000)
        guard let data = try? encoder.encode(s), let json = String(data: data, encoding: .utf8) else { return }
        lock.lock(); lastSend = Date(); let targets = Array(clients.values); lock.unlock()
        let frame = Conn.frame(json)
        for c in targets { c.send(frame) }
    }

    func addClient(_ c: Conn) {
        lock.lock(); clients[ObjectIdentifier(c)] = c; let snap = lastState; lock.unlock()
        if var snap { snap.ts = Int64(Date().timeIntervalSince1970 * 1000)
            if let data = try? encoder.encode(snap), let json = String(data: data, encoding: .utf8) { c.send(Conn.frame(json)) } }
    }
    func removeClient(_ c: Conn) { lock.lock(); clients[ObjectIdentifier(c)] = nil; lock.unlock() }

    // change-detection key. skips position/ts since those tick every second (client interpolates)
    private func signature(_ p: StatePayload) -> String {
        var s = "\(p.currentId ?? "")|\(p.latchedId ?? "")|\(p.latchedName ?? "")|\(p.active?.id ?? "")|"
        s += "\(p.showApp ? 1 : 0)|\(p.hidePaused ? 1 : 0)|\(p.layout)|\(p.launchOnStartup ? 1 : 0)|\(p.accent ?? "")||"
        for x in p.sessions {
            s += "\(x.id)~\(x.title ?? "")~\(x.artist ?? "")~\(x.album ?? "")~\(x.status)~\(x.isCurrent ? 1 : 0)~\(x.thumbnail == nil ? 0 : 1)~\(Int(x.duration));"
        }
        return s
    }

    private static let webRoot: URL = {
        let fm = FileManager.default
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("wwwroot")) }   // inside the .app
        candidates += [exeDir.appendingPathComponent("wwwroot"),
                       exeDir.appendingPathComponent("../wwwroot"),
                       URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("wwwroot"),
                       URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("../wwwroot")]
        for c in candidates where fm.fileExists(atPath: c.appendingPathComponent("overlay.html").path) { return c.standardizedFileURL }
        return exeDir.appendingPathComponent("wwwroot")
    }()

    func serveFile(_ path: String) -> (Data, String)? {
        let file: String
        switch path {
        case "/", "/control": file = "control.html"
        case "/overlay": file = "overlay.html"
        default: file = String(path.drop(while: { $0 == "/" }))
        }
        let full = Server.webRoot.appendingPathComponent(file).standardizedFileURL
        guard full.path.hasPrefix(Server.webRoot.path),
              let data = try? Data(contentsOf: full) else { return nil }
        return (data, contentType(full.pathExtension))
    }

    private func contentType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "ico": return "image/x-icon"
        default: return "application/octet-stream"
        }
    }

    private func loadSettings() {
        guard let data = try? Data(contentsOf: settingsPath),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return }
        latchedId = (s.latchedId?.isEmpty ?? true) ? nil : s.latchedId
        showApp = s.showApp; hidePaused = s.hidePaused
        layout = s.layout.isEmpty ? "classic" : s.layout
        accent = normalizeHex(s.accent)
    }

    private func saveSettings() {
        lock.lock()
        let s = Settings(latchedId: latchedId, showApp: showApp, hidePaused: hidePaused,
                         layout: layout, accent: accent.isEmpty ? nil : accent)
        lock.unlock()
        try? FileManager.default.createDirectory(at: settingsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: settingsPath) }
    }

    private let agentLabel = "com.yetanothernowplaying.widget"
    private var agentPath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    func startupEnabled() -> Bool { FileManager.default.fileExists(atPath: agentPath.path) }

    func setStartup(_ enabled: Bool) {
        if !enabled { try? FileManager.default.removeItem(at: agentPath); return }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        var args = "<string>\(exe)</string><string>--no-open</string>"
        if port != 8787 { args += "<string>--port</string><string>\(port)</string>" }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>\(agentLabel)</string>
        <key>ProgramArguments</key><array>\(args)</array>
        <key>RunAtLoad</key><true/>
        </dict></plist>
        """
        try? FileManager.default.createDirectory(at: agentPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? plist.write(to: agentPath, atomically: true, encoding: .utf8)
    }

    private func nilIfEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    // accepts "#rrggbb", "rrggbb", or "rgb"; returns "#rrggbb" or "" for default/invalid
    private func normalizeHex(_ hex: String?) -> String {
        guard var h = hex?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return "" }
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        if h.count != 6 || !h.allSatisfy({ $0.isHexDigit }) { return "" }
        return "#" + h.lowercased()
    }

    private func mimeOf(_ b: Data) -> String {
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8 { return "image/jpeg" }
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50 { return "image/png" }
        if b.count >= 2, b[0] == 0x42, b[1] == 0x4D { return "image/bmp" }
        if b.count >= 4, b[0] == 0x52, b[1] == 0x49 { return "image/webp" }
        return "image/png"
    }
}

// one TCP connection: parses HTTP, upgrades /ws, then talks websocket frames
final class Conn {
    private let conn: NWConnection
    private unowned let server: Server
    private var buf = Data()
    private var isWS = false

    init(connection: NWConnection, server: Server) { self.conn = connection; self.server = server }

    func start(on queue: DispatchQueue) {
        conn.stateUpdateHandler = { [weak self] s in guard let self else { return }; if case .cancelled = s { self.server.removeClient(self) } }
        conn.start(queue: queue)
        receive()   // the receive closure keeps a strong self, so the connection stays alive while it's open
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, done, error in
            if let data, !data.isEmpty { self.buf.append(data); self.isWS ? self.pumpFrames() : self.handleHTTP() }
            if done || error != nil { self.close(); return }
            self.receive()
        }
    }

    private func handleHTTP() {
        guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return }
        let head = String(data: buf.subdata(in: buf.startIndex..<headerEnd.lowerBound), encoding: .utf8) ?? ""
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.components(separatedBy: " ") ?? []
        let path = parts.count > 1 ? parts[1] : "/"

        if path == "/ws" {
            guard let key = headerValue(lines, "sec-websocket-key") else { reply(400); return }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in })
            buf.removeSubrange(buf.startIndex..<headerEnd.upperBound)
            isWS = true
            server.addClient(self)
            if !buf.isEmpty { pumpFrames() }
            return
        }

        if let (body, type) = server.serveFile(path) {
            let header = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            var out = Data(header.utf8); out.append(body)
            conn.send(content: out, completion: .contentProcessed { [weak self] _ in self?.close() })
        } else { reply(404) }
    }

    private func reply(_ code: Int) {
        let resp = "HTTP/1.1 \(code) \(code == 404 ? "Not Found" : "Bad Request")\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(resp.utf8), completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    private func headerValue(_ lines: [String], _ name: String) -> String? {
        for l in lines where l.lowercased().hasPrefix(name + ":") {
            return l.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private func pumpFrames() {
        while let (opcode, payload) = nextFrame() {
            switch opcode {
            case 0x1: if let s = String(data: payload, encoding: .utf8) { server.handleMessage(s) }
            case 0x8: close(); return
            case 0x9: conn.send(content: Conn.frame(payload, opcode: 0xA), completion: .contentProcessed { _ in })  // pong
            default: break
            }
        }
    }

    // pulls one client frame out of buf (client frames are always masked), or nil if it's not all here yet
    private func nextFrame() -> (UInt8, Data)? {
        let b = [UInt8](buf)
        guard b.count >= 2 else { return nil }
        let opcode = b[0] & 0x0F
        let masked = b[1] & 0x80 != 0
        var len = Int(b[1] & 0x7F)
        var i = 2
        if len == 126 { guard b.count >= 4 else { return nil }; len = Int(b[2]) << 8 | Int(b[3]); i = 4 }
        else if len == 127 { guard b.count >= 10 else { return nil }; len = 0; for k in 0..<8 { len = len << 8 | Int(b[2 + k]) }; i = 10 }
        var mask = [UInt8](repeating: 0, count: 4)
        if masked { guard b.count >= i + 4 else { return nil }; for k in 0..<4 { mask[k] = b[i + k] }; i += 4 }
        guard b.count >= i + len else { return nil }
        var payload = [UInt8](repeating: 0, count: len)
        for k in 0..<len { payload[k] = masked ? b[i + k] ^ mask[k % 4] : b[i + k] }
        buf.removeSubrange(buf.startIndex..<buf.index(buf.startIndex, offsetBy: i + len))
        return (opcode, Data(payload))
    }

    // server -> client frames go out unmasked
    static func frame(_ s: String, opcode: UInt8 = 0x1) -> Data { frame(Data(s.utf8), opcode: opcode) }
    static func frame(_ payload: Data, opcode: UInt8) -> Data {
        var f = Data([0x80 | opcode])
        let n = payload.count
        if n < 126 { f.append(UInt8(n)) }
        else if n < 65536 { f.append(126); f.append(UInt8(n >> 8)); f.append(UInt8(n & 0xFF)) }
        else { f.append(127); for shift in stride(from: 56, through: 0, by: -8) { f.append(UInt8((n >> shift) & 0xFF)) } }
        f.append(payload)
        return f
    }

    func send(_ frame: Data) { conn.send(content: frame, completion: .contentProcessed { _ in }) }
    private func close() { server.removeClient(self); conn.cancel() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let server: Server
    let openPanel: Bool
    private var item: NSStatusItem!
    private var controlURL: String { "http://localhost:\(server.port)/control" }
    private var overlayURL: String { "http://localhost:\(server.port)/overlay" }

    init(server: Server, openPanel: Bool) { self.server = server; self.openPanel = openPanel }

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Now Playing")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open control panel", action: #selector(openControl), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Copy overlay URL", action: #selector(copyOverlay), keyEquivalent: ""))
        menu.addItem(.separator())
        let startup = NSMenuItem(title: "Launch at login", action: #selector(toggleStartup), keyEquivalent: "")
        menu.addItem(startup)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        menu.delegate = self
        item.menu = menu

        if openPanel { NSWorkspace.shared.open(URL(string: controlURL)!) }
    }

    @objc private func openControl() { NSWorkspace.shared.open(URL(string: controlURL)!) }
    @objc private func copyOverlay() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(overlayURL, forType: .string)
    }
    @objc private func toggleStartup() { server.setStartup(!server.startupEnabled()) }
    @objc private func quit() { NSApp.terminate(nil) }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        menu.items.first(where: { $0.title == "Launch at login" })?.state = server.startupEnabled() ? .on : .off
    }
}

let args = CommandLine.arguments
var port: UInt16 = 8787
if let i = args.firstIndex(of: "--port"), i + 1 < args.count, let p = UInt16(args[i + 1]) { port = p }
let open = !args.contains("--no-open")

let server = Server(port: port)
do { try server.start() }
catch {
    let a = NSAlert()
    a.messageText = "Yet Another Now Playing Widget"
    a.informativeText = "Couldn't start on port \(port). It might be taken - try --port 9090.\n\n\(error.localizedDescription)"
    a.runModal()
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(server: server, openPanel: open)
app.delegate = delegate
app.run()
