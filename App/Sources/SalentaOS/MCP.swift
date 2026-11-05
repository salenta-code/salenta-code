import AppKit
import CryptoKit
import Foundation
import Network

// Ein eigener MCP-Client: Salenta Code spricht direkt mit MCP-Servern,
// über Streamable HTTP (mit OAuth 2.1 + PKCE + Dynamic Client Registration) oder stdio.

struct MCPServerSpec: Codable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var url: String?
    var command: String?
    var args: [String]?
    /// Umgebungsvariablen (stdio). Werden nie in data/mcp.json geschrieben, wenn sie aus fremden Konfigurationen stammen.
    var env: [String: String]?
    /// Zusätzliche HTTP-Header (z. B. Authorization aus ~/.claude.json). Nur im Speicher.
    var headers: [String: String]?
    var description: String?
    /// Woher der Eintrag kommt: "Salenta Code", "Claude Code", "Codex", "Junie", "Claude Desktop", "Cursor"
    var origin: String
    var auth: String?

    var isHTTP: Bool { url != nil }
    var transportLabel: String { isHTTP ? "HTTP" : "stdio" }
    var target: String { url ?? ([command ?? ""] + (args ?? [])).joined(separator: " ") }

    enum CodingKeys: String, CodingKey { case name, url, command, args, description, origin, auth }
}

struct MCPParam: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let type: String
    let description: String
    let enumValues: [String]
    let required: Bool
}

struct MCPTool: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let title: String
    let description: String
    let params: [MCPParam]
    let readOnly: Bool
    let destructive: Bool

    init(json: [String: Any]) {
        name = json["name"] as? String ?? "?"
        title = (json["title"] as? String) ?? ((json["annotations"] as? [String: Any])?["title"] as? String) ?? name
        description = json["description"] as? String ?? ""
        let schema = json["inputSchema"] as? [String: Any] ?? [:]
        let props = schema["properties"] as? [String: Any] ?? [:]
        let req = Set(schema["required"] as? [String] ?? [])
        params = props.keys.sorted { a, b in
            if req.contains(a) != req.contains(b) { return req.contains(a) }
            return a < b
        }.map { key in
            let p = props[key] as? [String: Any] ?? [:]
            var type = p["type"] as? String ?? (p["type"] as? [String])?.first(where: { $0 != "null" }) ?? "string"
            if p["enum"] != nil { type = "enum" }
            return MCPParam(name: key, type: type, description: p["description"] as? String ?? "",
                            enumValues: (p["enum"] as? [Any])?.map { "\($0)" } ?? [], required: req.contains(key))
        }
        let ann = json["annotations"] as? [String: Any] ?? [:]
        readOnly = ann["readOnlyHint"] as? Bool ?? false
        destructive = ann["destructiveHint"] as? Bool ?? false
    }
}

struct MCPResult {
    let text: String
    let isError: Bool
    /// Geparstes JSON, falls der Text JSON ist.
    var json: Any? {
        guard let d = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }
}

enum MCPError: LocalizedError {
    case http(Int, String)
    case rpc(String)
    case auth(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case let .http(code, body): "HTTP \(code): \(body.prefix(300))"
        case let .rpc(m): m
        case let .auth(m): "Anmeldung: \(m)"
        case let .transport(m): m
        }
    }
}

/// Eine Verbindung zu einem MCP-Server.
final class MCPConnection: ObservableObject {
    enum State: Equatable { case idle, connecting, connected, failed(String) }

    let spec: MCPServerSpec
    @Published var state: State = .idle
    @Published var tools: [MCPTool] = []
    @Published var serverName = ""

    private let lock = NSLock()
    private var _sessionID: String?
    private var _nextID = 1
    private var sessionID: String? {
        get { lock.lock(); defer { lock.unlock() }; return _sessionID }
        set { lock.lock(); _sessionID = newValue; lock.unlock() }
    }
    private func takeID() -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = _nextID
        _nextID += 1
        return id
    }
    /// Nach einem 401 mit fremdem Authorization-Header eigene OAuth-Anmeldung nutzen.
    private var ignoreHeaderAuth = false
    private var stdio: StdioTransport?
    private let protocolVersion = "2025-06-18"

    init(spec: MCPServerSpec) { self.spec = spec }

    // MARK: Öffentlich

    func connect(interactiveAuth: Bool = true) async {
        let already = await MainActor.run { () -> Bool in
            if state == .connected || state == .connecting { return true }
            state = .connecting
            return false
        }
        if already { return }
        do {
            let result = try await request("initialize", params: [
                "protocolVersion": protocolVersion,
                "capabilities": [String: Any](),
                "clientInfo": ["name": "Salenta Code", "version": "1.0"],
            ], interactiveAuth: interactiveAuth)
            let name = ((result as? [String: Any])?["serverInfo"] as? [String: Any])?["name"] as? String ?? spec.name
            try? await notify("notifications/initialized")
            CrashLog.mark("\(spec.name) initialized")
            let list = try await listTools()
            CrashLog.mark("\(spec.name) tools \(list.count)")
            await MainActor.run {
                serverName = name
                tools = list
                state = .connected
            }
        } catch {
            let message = error.localizedDescription
            await MainActor.run { state = .failed(message) }
        }
    }

    func disconnect() {
        stdio?.stop()
        stdio = nil
        sessionID = nil
        DispatchQueue.main.async { self.state = .idle; self.tools = [] }
    }

    func listTools() async throws -> [MCPTool] {
        var all: [MCPTool] = []
        var cursor: String?
        repeat {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let r = try await request("tools/list", params: params) as? [String: Any] ?? [:]
            all += (r["tools"] as? [[String: Any]] ?? []).map(MCPTool.init(json:))
            cursor = r["nextCursor"] as? String
        } while cursor != nil && all.count < 1000
        return all
    }

    func callTool(_ name: String, arguments: [String: Any]) async throws -> MCPResult {
        let r = try await request("tools/call", params: ["name": name, "arguments": arguments]) as? [String: Any] ?? [:]
        let content = r["content"] as? [[String: Any]] ?? []
        var parts: [String] = content.compactMap { c in
            if let t = c["text"] as? String { return t }
            if c["type"] as? String == "image" { return "[Bild]" }
            if let res = c["resource"] as? [String: Any] { return res["text"] as? String ?? res["uri"] as? String }
            return nil
        }
        if parts.isEmpty, let structured = r["structuredContent"],
           let d = try? JSONSerialization.data(withJSONObject: structured, options: [.prettyPrinted]) {
            parts = [String(decoding: d, as: UTF8.self)]
        }
        return MCPResult(text: parts.joined(separator: "\n\n"), isError: r["isError"] as? Bool ?? false)
    }

    // MARK: JSON-RPC

    private func request(_ method: String, params: [String: Any], interactiveAuth: Bool = false) async throws -> Any? {
        let id = takeID()
        let body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let response: [String: Any]
        if spec.isHTTP {
            response = try await httpSend(body, expectID: id, interactiveAuth: interactiveAuth)
        } else {
            if stdio == nil {
                let t = StdioTransport(spec: spec)
                try t.start()
                stdio = t
            }
            response = try await stdio!.send(body, id: id)
        }
        if let err = response["error"] as? [String: Any] {
            throw MCPError.rpc(err["message"] as? String ?? "Fehler")
        }
        return response["result"]
    }

    private func notify(_ method: String) async throws {
        let body: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if spec.isHTTP {
            _ = try? await httpSend(body, expectID: nil, interactiveAuth: false)
        } else {
            try stdio?.write(body)
        }
    }

    // MARK: Streamable HTTP

    private func httpSend(_ body: [String: Any], expectID: Int?, interactiveAuth: Bool, retried: Bool = false) async throws -> [String: Any] {
        guard let urlString = spec.url, let url = URL(string: urlString) else { throw MCPError.transport("Ungültige URL") }
        var req = URLRequest(url: url, timeoutInterval: 90)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { req.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        var hasHeaderAuth = false
        for (k, raw) in spec.headers ?? [:] {
            let v = Self.expandEnv(raw)
            if k.lowercased() == "authorization" {
                if ignoreHeaderAuth || v.contains("${") || v.trimmingCharacters(in: .whitespaces).hasSuffix("Bearer") { continue }
                hasHeaderAuth = true
            }
            req.setValue(v, forHTTPHeaderField: k)
        }
        if !hasHeaderAuth, let token = await OAuthManager.shared.validToken(for: urlString) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw MCPError.transport("Keine Antwort") }
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = sid }

        if http.statusCode == 401 || http.statusCode == 403 {
            MCPLog.write("\(spec.name): HTTP \(http.statusCode) retried=\(retried) headerAuth=\(hasHeaderAuth) www-auth=\(http.value(forHTTPHeaderField: "WWW-Authenticate") ?? "-") body=\(String(decoding: data.prefix(300), as: UTF8.self))")
            if hasHeaderAuth && !ignoreHeaderAuth {
                ignoreHeaderAuth = true
                return try await httpSend(body, expectID: expectID, interactiveAuth: interactiveAuth, retried: false)
            }
            guard !retried else { throw MCPError.auth("Zugriff verweigert (\(http.statusCode)) – Details in logs/mcp.log") }
            if await OAuthManager.shared.refresh(for: urlString) {
                return try await httpSend(body, expectID: expectID, interactiveAuth: interactiveAuth, retried: true)
            }
            guard interactiveAuth else { throw MCPError.auth("Anmeldung nötig – auf „Verbinden“ klicken") }
            let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate")
            try await OAuthManager.shared.authorize(serverURL: url, challenge: challenge)
            return try await httpSend(body, expectID: expectID, interactiveAuth: false, retried: true)
        }
        if http.statusCode == 404, sessionID != nil, !retried {
            sessionID = nil
            throw MCPError.transport("Sitzung abgelaufen – bitte neu verbinden")
        }
        if http.statusCode == 202 || expectID == nil { return [:] }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }

        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let text = String(decoding: data, as: UTF8.self)
        if type.contains("text/event-stream") {
            // SSE: "data:"-Zeilen je Ereignis sammeln und die Antwort mit passender id finden.
            var buffer = ""
            for line in text.components(separatedBy: "\n") {
                let l = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                if l.hasPrefix("data:") {
                    buffer += String(l.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                } else if l.isEmpty, !buffer.isEmpty {
                    if let msg = Self.parse(buffer), Self.matches(msg, expectID) { return msg }
                    buffer = ""
                }
            }
            if !buffer.isEmpty, let msg = Self.parse(buffer), Self.matches(msg, expectID) { return msg }
            throw MCPError.transport("Keine Antwort im Ereignisstrom")
        }
        if let msg = Self.parse(text) { return msg }
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let msg = arr.first(where: { Self.matches($0, expectID) }) { return msg }
        throw MCPError.transport("Unerwartete Antwort: \(text.prefix(200))")
    }

    /// ${VAR} und $VAR aus der Umgebung einsetzen.
    static func expandEnv(_ s: String) -> String {
        var out = s
        let env = ProcessInfo.processInfo.environment
        for (k, v) in env where out.contains(k) {
            out = out.replacingOccurrences(of: "${\(k)}", with: v)
        }
        return out
    }

    private static func parse(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private static func matches(_ msg: [String: Any], _ id: Int?) -> Bool {
        guard let id else { return true }
        if let i = msg["id"] as? Int { return i == id }
        if let s = msg["id"] as? String { return s == "\(id)" }
        return false
    }
}

// MARK: - stdio

final class StdioTransport {
    let spec: MCPServerSpec
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var waiting: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private let lock = NSLock()

    init(spec: MCPServerSpec) { self.spec = spec }

    func start() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let cmd = ([spec.command ?? ""] + (spec.args ?? [])).map(Shell.quote).joined(separator: " ")
        p.arguments = ["-l", "-c", "exec \(cmd)"]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in spec.env ?? [:] { env[k] = v }
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            // Leere Daten = Dateiende (Server beendet). Ohne Abmelden feuert der Handler endlos weiter → 100 % CPU.
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            self?.receive(d)
        }
        p.terminationHandler = { [weak self] _ in self?.failAll("Server beendet") }
        try p.run()
        process = p
        input = inPipe.fileHandleForWriting
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    func write(_ body: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: body)
        data.append(0x0A)
        input?.write(data)
    }

    func send(_ body: [String: Any], id: Int) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<[String: Any], Error>) in
            lock.lock()
            waiting[id] = c
            lock.unlock()
            do { try write(body) } catch {
                lock.lock(); waiting[id] = nil; lock.unlock()
                c.resume(throwing: error)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 90) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let pending = self.waiting.removeValue(forKey: id)
                self.lock.unlock()
                pending?.resume(throwing: MCPError.transport("Zeitüberschreitung"))
            }
        }
    }

    private func receive(_ d: Data) {
        lock.lock()
        buffer.append(d)
        var messages: [[String: Any]] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let msg = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { messages.append(msg) }
        }
        var resumes: [(CheckedContinuation<[String: Any], Error>, [String: Any])] = []
        for m in messages {
            if let id = m["id"] as? Int, let c = waiting.removeValue(forKey: id) { resumes.append((c, m)) }
        }
        lock.unlock()
        for (c, m) in resumes { c.resume(returning: m) }
    }

    private func failAll(_ reason: String) {
        lock.lock()
        let all = waiting
        waiting = [:]
        lock.unlock()
        for (_, c) in all { c.resume(throwing: MCPError.transport(reason)) }
    }
}

// MARK: - OAuth 2.1 (PKCE + Dynamic Client Registration), Tokens im Schlüsselbund

final class OAuthManager: NSObject {
    static let shared = OAuthManager()
    /// Loopback-Redirect wie bei Claude Code (RFC 8252). Port fest, damit die Registrierung stabil bleibt.
    static let port: UInt16 = 47821
    static let redirectURI = "http://localhost:47821/callback"

    struct Stored: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var clientID: String
        var clientSecret: String?
        var tokenEndpoint: String
        var resource: String
    }

    func validToken(for server: String) async -> String? {
        guard let s = Keychain.load(server) else { return nil }
        if let exp = s.expiresAt, exp < Date().addingTimeInterval(60), s.refreshToken != nil {
            return await refresh(for: server) ? Keychain.load(server)?.accessToken : nil
        }
        return s.accessToken
    }

    func hasToken(for server: String) -> Bool { Keychain.load(server) != nil }

    func signOut(_ server: String) { Keychain.delete(server) }

    /// Erneuert das Token. true, wenn ein neues Token vorliegt.
    func refresh(for server: String) async -> Bool {
        guard var s = Keychain.load(server), let refresh = s.refreshToken,
              let url = URL(string: s.tokenEndpoint) else { return false }
        var form = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": s.clientID, "resource": s.resource]
        if let secret = s.clientSecret { form["client_secret"] = secret }
        guard let json = try? await Self.postForm(url, form), let access = json["access_token"] as? String else { return false }
        s.accessToken = access
        if let r = json["refresh_token"] as? String { s.refreshToken = r }
        s.expiresAt = (json["expires_in"] as? Double).map { Date().addingTimeInterval($0) }
        Keychain.save(s, for: server)
        return true
    }

    /// Kompletter Anmeldeablauf im Browser-Fenster.
    func authorize(serverURL: URL, challenge: String?) async throws {
        // 1. Protected Resource Metadata
        var prm: [String: Any]?
        if let challenge, let range = challenge.range(of: "resource_metadata=\"") {
            let rest = challenge[range.upperBound...]
            if let end = rest.firstIndex(of: "\""), let u = URL(string: String(rest[..<end])) {
                prm = try? await Self.getJSON(u)
            }
        }
        let origin = "\(serverURL.scheme ?? "https")://\(serverURL.host ?? "")\(serverURL.port.map { ":\($0)" } ?? "")"
        if prm == nil {
            let path = serverURL.path == "/" ? "" : serverURL.path
            for candidate in ["\(origin)/.well-known/oauth-protected-resource\(path)", "\(origin)/.well-known/oauth-protected-resource"] {
                if let u = URL(string: candidate), let j = try? await Self.getJSON(u) { prm = j; break }
            }
        }
        let issuer = (prm?["authorization_servers"] as? [String])?.first ?? origin
        let scopes = (prm?["scopes_supported"] as? [String])?.joined(separator: " ")

        // 2. Authorization Server Metadata
        var asm: [String: Any] = [:]
        if let iu = URL(string: issuer) {
            let iOrigin = "\(iu.scheme ?? "https")://\(iu.host ?? "")\(iu.port.map { ":\($0)" } ?? "")"
            let iPath = iu.path == "/" ? "" : iu.path
            for candidate in ["\(iOrigin)/.well-known/oauth-authorization-server\(iPath)",
                              "\(iOrigin)/.well-known/openid-configuration\(iPath)",
                              "\(issuer)/.well-known/openid-configuration"] {
                if let u = URL(string: candidate), let j = try? await Self.getJSON(u), j["authorization_endpoint"] != nil { asm = j; break }
            }
        }
        let base = issuer.hasSuffix("/") ? String(issuer.dropLast()) : issuer
        let authEndpoint = asm["authorization_endpoint"] as? String ?? "\(base)/authorize"
        let tokenEndpoint = asm["token_endpoint"] as? String ?? "\(base)/token"
        let registration = asm["registration_endpoint"] as? String ?? "\(base)/register"

        // 3. Dynamic Client Registration
        guard let regURL = URL(string: registration) else { throw MCPError.auth("Keine Registrierungsadresse") }
        let reg = try await Self.postJSON(regURL, [
            "client_name": "Salenta Code",
            "redirect_uris": [Self.redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])
        guard let clientID = reg["client_id"] as? String else { throw MCPError.auth("Client-Registrierung fehlgeschlagen") }
        MCPLog.write("OAuth \(serverURL.host ?? ""): issuer=\(issuer) auth=\(authEndpoint) token=\(tokenEndpoint) scopes=\(scopes ?? "-")")
        let clientSecret = reg["client_secret"] as? String

        // 4. PKCE + Browser
        let verifier = Self.randomString(64)
        let challengeValue = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomString(24)
        guard var comps = URLComponents(string: authEndpoint) else { throw MCPError.auth("Ungültige Anmeldeadresse") }
        var items = comps.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge", value: challengeValue),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: serverURL.absoluteString),
        ]
        if let scopes, !scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: scopes)) }
        comps.queryItems = items
        guard let authURL = comps.url else { throw MCPError.auth("Ungültige Anmeldeadresse") }

        let server = LoopbackServer(port: Self.port)
        let callbackTask = Task { try await server.waitForCallback(timeout: 300) }
        try await Task.sleep(nanoseconds: 300_000_000)
        await MainActor.run { Launcher.open(authURL) }
        let callback = try await callbackTask.value
        let q = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let err = q.first(where: { $0.name == "error" })?.value { throw MCPError.auth(err) }
        guard q.first(where: { $0.name == "state" })?.value == state,
              let code = q.first(where: { $0.name == "code" })?.value else { throw MCPError.auth("Ungültige Rückmeldung") }

        // 5. Token
        guard let tokenURL = URL(string: tokenEndpoint) else { throw MCPError.auth("Ungültige Token-Adresse") }
        var form = ["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI,
                    "client_id": clientID, "code_verifier": verifier, "resource": serverURL.absoluteString]
        if let clientSecret { form["client_secret"] = clientSecret }
        let tok = try await Self.postForm(tokenURL, form)
        guard let access = tok["access_token"] as? String else { throw MCPError.auth("Kein Token erhalten") }
        MCPLog.write("OAuth \(serverURL.host ?? ""): Token erhalten (type=\(tok["token_type"] ?? "-"), scope=\(tok["scope"] ?? "-"), expires=\(tok["expires_in"] ?? "-"))")
        let stored = Stored(accessToken: access, refreshToken: tok["refresh_token"] as? String,
                            expiresAt: (tok["expires_in"] as? Double).map { Date().addingTimeInterval($0) },
                            clientID: clientID, clientSecret: clientSecret, tokenEndpoint: tokenEndpoint,
                            resource: serverURL.absoluteString)
        Keychain.save(stored, for: serverURL.absoluteString)
    }

    // MARK: HTTP-Helfer

    static func getJSON(_ url: URL) async throws -> [String: Any] {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MCPError.transport("kein JSON") }
        return j
    }

    static func postJSON(_ url: URL, _ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code), let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.http(code, String(decoding: data, as: UTF8.self))
        }
        return j
    }

    static func postForm(_ url: URL, _ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code), let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.http(code, String(decoding: data, as: UTF8.self))
        }
        return j
    }

    static func randomString(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<n).map { _ in chars.randomElement()! })
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Token-Ablage: ~/Library/Application Support/AgenticOS/mcp-tokens.json (nur für deinen Benutzer lesbar, 0600).
/// Bewusst nicht im Schlüsselbund: die App ist ad hoc signiert, der Schlüsselbund würde nach jedem Neubau nachfragen.
/// Liegt außerhalb des Salenta-Code-Ordners, damit keine Tokens in Repo oder Vault landen.
enum Keychain {
    private static let lock = NSLock()

    private static var url: URL {
        let dir = Paths.support
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("mcp-tokens.json")
    }

    private static func readAll() -> [String: OAuthManager.Stored] {
        guard let d = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: OAuthManager.Stored].self, from: d)) ?? [:]
    }

    private static func writeAll(_ all: [String: OAuthManager.Stored]) {
        guard let d = try? JSONEncoder().encode(all) else { return }
        try? d.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func save(_ value: OAuthManager.Stored, for account: String) {
        lock.lock(); defer { lock.unlock() }
        var all = readAll()
        all[account] = value
        writeAll(all)
    }

    static func load(_ account: String) -> OAuthManager.Stored? {
        lock.lock(); defer { lock.unlock() }
        return readAll()[account]
    }

    static func delete(_ account: String) {
        lock.lock(); defer { lock.unlock() }
        var all = readAll()
        all[account] = nil
        writeAll(all)
    }
}

/// Winziger HTTP-Server auf localhost, der den OAuth-Rückruf aus dem Browser annimmt.
final class LoopbackServer {
    private let port: UInt16
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, Error>?
    private let lock = NSLock()

    init(port: UInt16) { self.port = port }

    func waitForCallback(timeout: TimeInterval) async throws -> URL {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            lock.lock(); continuation = c; lock.unlock()
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                guard let p = NWEndpoint.Port(rawValue: port) else { throw MCPError.auth("Port") }
                let l = try NWListener(using: params, on: p)
                l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
                l.stateUpdateHandler = { [weak self] state in
                    if case let .failed(err) = state { self?.finish(.failure(MCPError.auth("Port \(self?.port ?? 0) belegt: \(err)"))) }
                }
                l.start(queue: .global())
                listener = l
            } catch {
                finish(.failure(error))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(MCPError.auth("Anmeldung nicht abgeschlossen (Zeitüberschreitung)")))
            }
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let firstLine = text.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.components(separatedBy: " ")
            let path = parts.count > 1 ? parts[1] : "/"
            let isCallback = path.hasPrefix("/callback")
            let html = isCallback
                ? "<html><body style='font-family:-apple-system;padding:40px'><h2>✓ Angemeldet</h2><p>Du kannst dieses Fenster schließen und zu Salenta Code zurückkehren.</p></body></html>"
                : "<html><body>Salenta Code</body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
            if isCallback, let url = URL(string: "http://localhost:\(self?.port ?? 0)\(path)") {
                self?.finish(.success(url))
            }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        guard let c else { return }
        listener?.cancel()
        listener = nil
        c.resume(with: result)
    }
}

enum MCPLog {
    static func write(_ text: String) {
        let url = Paths.root.appendingPathComponent("logs/mcp.log")
        let line = "\(Date()): \(text)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
