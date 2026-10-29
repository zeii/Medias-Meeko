// Native macOS app: hosts ui.html in a WKWebView and implements its /api/* calls in Swift,
// so nothing (no Python, no local server) has to be installed.

import Cocoa
import UniformTypeIdentifiers
import WebKit

let apiBase = "https://api.meeko.app"
let familyAPI = apiBase + "/family/v1"
let home = FileManager.default.homeDirectoryForCurrentUser
let tokenFile = home.appendingPathComponent(".config/meeko/token.json")  // shared with meeko_download.py
let defaultOut = home.appendingPathComponent("Pictures/Meeko")
let perPage = 30  // same value as the official web app

struct APIError: Error {
    let status: Int
    let message: String
}

struct Media {
    let id: String
    let url: String
    let video: Bool
    let type: String?
    let description: String?
    let taken: Date
}

// MARK: - Dates

func localFormatter(_ format: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = format
    return f
}

let isoLocal: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.timeZone = .current
    return f
}()

/// taken_at is either a unix timestamp or an ISO 8601 string depending on the endpoint.
func parseDate(_ value: Any?) -> Date? {
    if let n = value as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
    guard let s = value as? String else { return nil }
    if let d = Double(s) { return Date(timeIntervalSince1970: d) }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = iso.date(from: s) { return d }
    iso.formatOptions = [.withInternetDateTime]
    if let d = iso.date(from: s) { return d }
    return localFormatter("yyyy-MM-dd HH:mm:ss").date(from: s)
}

// MARK: - Meeko API

enum Meeko {
    static func call(_ method: String, _ url: URL, token: String? = nil, body: [String: Any]? = nil) async throws -> Any {
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(decoding: data, as: UTF8.self)
        if status == 401 { throw APIError(status: 401, message: "Session expirée, reconnecte-toi.") }
        if status == 422 && text.contains("invalid_credentials") { throw APIError(status: 401, message: "Identifiants invalides.") }
        guard (200..<300).contains(status) else {
            throw APIError(status: 502, message: "Meeko a répondu \(status) : \(text.prefix(200))")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    static func login(email: String, password: String) async throws -> String {
        let res = try await call("POST", URL(string: apiBase + "/v2/family/auth/login")!,
                                 body: ["email": email, "password": password])
        guard let token = (res as? [String: Any])?["token"] as? String else {
            throw APIError(status: 502, message: "Réponse de connexion inattendue.")
        }
        return token
    }

    /// The API returns newest first, so the first item older than `since` ends the scan.
    static func collect(token: String, since: Date, until: Date) async throws -> [Media] {
        var result: [Media] = []
        var page = 1
        while true {
            var comps = URLComponents(string: familyAPI + "/photos")!
            comps.queryItems = [URLQueryItem(name: "per_page", value: "\(perPage)"), URLQueryItem(name: "page", value: "\(page)")]
            let res = try await call("GET", comps.url!, token: token) as? [String: Any] ?? [:]
            for raw in res["data"] as? [[String: Any]] ?? [] {
                guard let taken = parseDate(raw["taken_at"] ?? raw["created_at"]),
                      let url = raw["photo_url"] as? String, let id = raw["id"] else { continue }
                if taken < since { return result }
                if taken <= until {
                    result.append(Media(id: "\(id)", url: url, video: (raw["video"] as? Bool) ?? false,
                                        type: raw["type"] as? String, description: raw["description"] as? String, taken: taken))
                }
            }
            let last = (res["last_page"] as? NSNumber)?.intValue ?? page
            if page >= last { return result }
            page += 1
        }
    }
}

// MARK: - Token & files

func loadToken() -> String? {
    guard let data = try? Data(contentsOf: tokenFile),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return obj["token"] as? String
}

func saveToken(_ token: String?) {
    let fm = FileManager.default
    guard let token else { try? fm.removeItem(at: tokenFile); return }
    try? fm.createDirectory(at: tokenFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: ["token": token]) {
        fm.createFile(atPath: tokenFile.path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}

func folder(_ out: URL, _ m: Media) -> URL {
    out.appendingPathComponent(localFormatter("yyyy").string(from: m.taken))
        .appendingPathComponent(localFormatter("MM").string(from: m.taken))
}

func stem(_ m: Media) -> String { "\(localFormatter("yyyy-MM-dd_HHmmss").string(from: m.taken))_\(m.id)" }

func existingFile(_ out: URL, _ m: Media) -> URL? {
    let dir = folder(out, m)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.first { $0.hasPrefix(stem(m) + ".") && !$0.hasSuffix(".part") }.map { dir.appendingPathComponent($0) }
}

func fileExtension(_ m: Media, mime: String?) -> String {
    let fromURL = URL(string: m.url)?.pathExtension.lowercased() ?? ""
    if !fromURL.isEmpty && fromURL.count <= 4 { return fromURL }
    // Same order as meeko_download.py so both tools produce identical file names.
    if let t = m.type, !t.isEmpty, !t.contains("/") { return t.lowercased() }
    if let mime, let ext = UTType(mimeType: mime)?.preferredFilenameExtension { return ext }
    return m.video ? "mp4" : "jpg"
}

func loadManifest(_ out: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: out.appendingPathComponent("manifest.json")),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return obj
}

func saveManifest(_ out: URL, _ manifest: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
        try? data.write(to: out.appendingPathComponent("manifest.json"))
    }
}

/// Downloads one media unless already present. Returns true when a file was written.
func save(_ m: Media, to out: URL, manifest: inout [String: Any]) async throws -> Bool {
    if existingFile(out, m) != nil { return false }
    let (tmp, resp) = try await URLSession.shared.download(from: URL(string: m.url)!)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else { throw APIError(status: 502, message: "HTTP \(status)") }
    let dir = folder(out, m)
    let fm = FileManager.default
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let dest = dir.appendingPathComponent("\(stem(m)).\(fileExtension(m, mime: resp.mimeType))")
    try? fm.removeItem(at: dest)
    try fm.moveItem(at: tmp, to: dest)
    try? fm.setAttributes([.modificationDate: m.taken, .creationDate: m.taken], ofItemAtPath: dest.path)
    manifest[m.id] = [
        "file": dest.path.replacingOccurrences(of: out.path + "/", with: ""),
        "taken_at": isoLocal.string(from: m.taken),
        "video": m.video,
        "description": m.description.map { $0 as Any } ?? NSNull(),
    ]
    return true
}

// MARK: - Bridge between ui.html and Swift

@MainActor
final class Bridge: NSObject, WKURLSchemeHandler, WKScriptMessageHandlerWithReply {
    var token = loadToken()
    var items: [String: Media] = [:]
    var job: [String: Any] = ["running": false, "total": 0, "done": 0, "skipped": 0, "failed": 0,
                              "current": NSNull(), "out": NSNull(), "error": NSNull()]

    // Serves the page itself (meeko://app/) and its favicon from the bundle.
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let path = task.request.url?.path ?? "/"
        let (file, mime) = path == "/favicon.png" ? ("meeko-icon.png", "image/png") : ("ui.html", "text/html")
        let data = (try? Data(contentsOf: Bundle.main.resourceURL!.appendingPathComponent(file))) ?? Data()
        task.didReceive(HTTPURLResponse(url: task.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        let msg = message.body as? [String: Any] ?? [:]
        let path = msg["path"] as? String ?? ""
        let body = msg["body"] as? [String: Any] ?? [:]
        Task { @MainActor in
            let (status, data) = await self.route(path, body)
            replyHandler(["status": status, "data": data], nil)
        }
    }

    func outDir(_ body: [String: Any]) -> URL {
        let raw = (body["out"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return raw.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? defaultOut
    }

    func route(_ path: String, _ body: [String: Any]) async -> (Int, Any) {
        do {
            switch path {
            case "/api/status":
                return (200, ["logged_in": token != nil, "default_out": defaultOut.path])
            case "/api/progress":
                return (200, job)
            case "/api/login":
                let t = try await Meeko.login(email: (body["email"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                                              password: body["password"] as? String ?? "")
                token = t
                saveToken(t)
                return (200, ["ok": true])
            case "/api/logout":
                token = nil
                saveToken(nil)
                return (200, ["ok": true])
            case "/api/list":
                return try await list(body)
            case "/api/download":
                return startDownload(body)
            case "/api/choose-folder":
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.prompt = "Choisir"
                panel.message = "Où enregistrer les photos et vidéos ?"
                panel.directoryURL = outDir(body)
                guard panel.runModal() == .OK, let url = panel.url else { return (200, ["cancelled": true]) }
                return (200, ["path": url.path])
            case "/api/open":
                let out = outDir(body)
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                NSWorkspace.shared.open(out)
                return (200, ["ok": true])
            case "/api/quit":
                if job["running"] as? Bool == true { return (409, ["error": "Un téléchargement est en cours."]) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
                return (200, ["ok": true])
            default:
                return (404, ["error": "not found"])
            }
        } catch let e as APIError {
            if e.status == 401 && path != "/api/login" { token = nil }
            return (e.status, ["error": e.message])
        } catch {
            return (500, ["error": error.localizedDescription])
        }
    }

    func list(_ body: [String: Any]) async throws -> (Int, Any) {
        guard let token else { throw APIError(status: 401, message: "Connecte-toi.") }
        let day = localFormatter("yyyy-MM-dd")
        let since = day.date(from: body["since"] as? String ?? "") ?? .distantPast  // no start date: whole history
        var until = Date()
        if let u = body["until"] as? String, let d = day.date(from: u) {
            until = Calendar.current.date(byAdding: .day, value: 1, to: d)!.addingTimeInterval(-0.001)
        }
        let out = outDir(body)
        let media = try await Meeko.collect(token: token, since: since, until: until)
        items = Dictionary(media.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return (200, ["items": media.map { m -> [String: Any] in
            ["id": m.id, "taken_at": isoLocal.string(from: m.taken), "video": m.video, "url": m.url,
             "description": m.description ?? NSNull(), "present": existingFile(out, m) != nil]
        }])
    }

    func startDownload(_ body: [String: Any]) -> (Int, Any) {
        if job["running"] as? Bool == true { return (409, ["error": "Un téléchargement est déjà en cours."]) }
        let out = outDir(body)
        let selected = (body["ids"] as? [String] ?? []).compactMap { items[$0] }.sorted { $0.taken < $1.taken }
        job = ["running": true, "total": selected.count, "done": 0, "skipped": 0, "failed": 0,
               "current": NSNull(), "out": out.path, "error": NSNull()]
        Task { @MainActor in
            var manifest = loadManifest(out)
            let label = localFormatter("dd/MM/yyyy HH:mm")
            for m in selected {
                job["current"] = label.string(from: m.taken)
                var key = "failed"
                do { key = try await save(m, to: out, manifest: &manifest) ? "done" : "skipped" } catch {
                    NSLog("Médias Meeko: échec %@ : %@", m.id, error.localizedDescription)
                }
                job[key] = (job[key] as? Int ?? 0) + 1
            }
            if !manifest.isEmpty { saveManifest(out, manifest) }
            job["running"] = false
            job["current"] = NSNull()
        }
        return (200, ["ok": true])
    }
}

// MARK: - App shell

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, WKUIDelegate, WKNavigationDelegate {
    var window: NSWindow!
    let bridge = Bridge()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(bridge, forURLScheme: "meeko")
        config.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "meeko")
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.uiDelegate = self
        web.navigationDelegate = self

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1150, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Médias Meeko"
        window.contentView = web
        window.center()
        window.setFrameAutosaveName("main")
        window.makeKeyAndOrderFront(nil)
        web.load(URLRequest(url: URL(string: "meeko://app/")!))
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // window.open(...) from the page ("open original") goes to the default browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, url.scheme != "meeko", action.targetFrame?.isMainFrame == true {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}

// Without an Edit menu, Cmd+C / Cmd+V do nothing in the login fields.
func buildMenu() -> NSMenu {
    let main = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Masquer Médias Meeko", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quitter Médias Meeko", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    main.addItem(appItem)

    let editItem = NSMenuItem()
    let edit = NSMenu(title: "Édition")
    edit.addItem(withTitle: "Annuler", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Rétablir", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit
    main.addItem(editItem)

    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Fenêtre")
    windowMenu.addItem(withTitle: "Réduire", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Fermer", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowItem.submenu = windowMenu
    main.addItem(windowItem)
    return main
}

@main
enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.mainMenu = buildMenu()
        app.run()
    }
}
