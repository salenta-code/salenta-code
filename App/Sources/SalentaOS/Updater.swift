import AgenticOSKit
import AppKit
import CryptoKit
import SwiftUI

// Updates für alle, die Salenta Code installiert haben:
//  • schaut einmal am Tag auf GitHub nach (latest.json im neuesten Release)
//  • lädt die neue Version, prüft Prüfsumme UND Signatur (gleiche Developer ID wie diese App) UND den Selbsttest
//  • tauscht die App erst aus, wenn keine Agents laufen – die vorige Version bleibt zum Zurückholen
// Entwickler-Versionen (aus dem Quellcode gebaut) aktualisieren sich nicht selbst – dort gilt „neu bauen“.

struct ReleaseInfo: Codable, Equatable {
    var version: String
    var url: String
    var sha256: String
    var minimumSystemVersion: String?
    var published: String?
    var notes: String?
}

final class Updater: ObservableObject {
    static let shared = Updater()
    enum Phase: Equatable { case idle, checking, downloading(Double), verifying, waitingForAgents, installing, failed(String) }

    @Published private(set) var available: ReleaseInfo?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastCheck: Date?
    weak var agents: AgentManager?
    private var timer: Timer?

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var repo: String {
        let r = (Bundle.main.object(forInfoDictionaryKey: "SCUpdateRepo") as? String) ?? ""
        return r.hasPrefix("__") ? "" : r
    }
    var enabled: Bool { !Paths.isDevBuild && !Self.repo.isEmpty }
    var auto: Bool { UserDefaults.standard.object(forKey: "update.auto") as? Bool ?? true }
    var beta: Bool { UserDefaults.standard.bool(forKey: "update.beta") }
    static var previous: URL { Paths.support.appendingPathComponent("previous/Salenta Code.app") }

    func start(agents: AgentManager) {
        self.agents = agents
        guard enabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check() }
        timer?.tolerance = 600
    }

    // MARK: Nachsehen

    func check(manual: Bool = false) {
        guard enabled, phase == .idle || manual, LocalFirst.shared.isOnline else { return }
        phase = .checking
        let api = beta ? "https://api.github.com/repos/\(Self.repo)/releases?per_page=10"
                       : "https://api.github.com/repos/\(Self.repo)/releases/latest"
        var r = URLRequest(url: URL(string: api)!, timeoutInterval: 20)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("Salenta-Code-Updater", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: r) { [weak self] d, _, _ in
            guard let self else { return }
            // latest.json aus dem (neuesten passenden) Release holen
            var assetURL: String?
            if let d, let j = try? JSONSerialization.jsonObject(with: d) {
                let releases = (j as? [[String: Any]]) ?? [(j as? [String: Any]) ?? [:]]
                let pick = releases.first { self.beta || ($0["prerelease"] as? Bool) != true }
                assetURL = ((pick?["assets"] as? [[String: Any]]) ?? []).first { ($0["name"] as? String) == "latest.json" }?["browser_download_url"] as? String
            }
            guard let a = assetURL, let u = URL(string: a), let data = try? Data(contentsOf: u),
                  let info = try? JSONDecoder().decode(ReleaseInfo.self, from: data) else {
                DispatchQueue.main.async { self.phase = .idle; self.lastCheck = Date() }
                return
            }
            DispatchQueue.main.async {
                self.lastCheck = Date()
                self.phase = .idle
                guard Self.newer(info.version, than: Self.current), Self.fitsSystem(info.minimumSystemVersion) else { self.available = nil; return }
                let isNew = self.available?.version != info.version
                self.available = info
                if isNew {
                    Notifier.push("Salenta Code", L("Update verfügbar: ") + info.version, priority: 3, tags: "arrow_up")
                    CrashLog.mark("Update verfügbar: \(info.version)")
                }
                if self.auto { self.install() }
            }
        }.resume()
    }

    /// Versionsvergleich 0.10.0 > 0.9.2, 0.3.0 > 0.3.0-beta.2
    static func newer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> ([Int], String) {
            let main = v.split(separator: "-", maxSplits: 1)
            return (main[0].split(separator: ".").map { Int($0) ?? 0 }, main.count > 1 ? String(main[1]) : "")
        }
        let (x, xs) = parts(a), (y, ys) = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        if xs.isEmpty != ys.isEmpty { return xs.isEmpty }   // Fertige Version schlägt Beta gleicher Nummer
        return xs > ys
    }

    static func fitsSystem(_ min: String?) -> Bool {
        guard let min else { return true }
        let p = min.split(separator: ".").map { Int($0) ?? 0 }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return (v.majorVersion, v.minorVersion) >= (p.first ?? 0, p.count > 1 ? p[1] : 0)
    }

    // MARK: Installieren

    func install(force: Bool = false) {
        guard let info = available, enabled else { return }
        switch phase { case .downloading, .verifying, .installing: return; default: break }
        // nie mitten in der Arbeit: warten, bis keine Agents laufen
        if !force, (agents?.runningCount ?? 0) > 0 {
            phase = .waitingForAgents
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                if self?.phase == .waitingForAgents { self?.phase = .idle; self?.install() }
            }
            return
        }
        guard let url = URL(string: info.url) else { return }
        phase = .downloading(0)
        let task = URLSession.shared.downloadTask(with: url) { [weak self] file, _, err in
            guard let self else { return }
            guard let file, err == nil else { self.fail(L("Download fehlgeschlagen")); return }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("sc-update-\(UUID().uuidString)")
            let zip = work.appendingPathComponent("update.zip")
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: file, to: zip)
            DispatchQueue.main.async { self.phase = .verifying }
            DispatchQueue.global(qos: .userInitiated).async { self.verifyAndSwap(zip: zip, work: work, info: info) }
        }
        observation = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            DispatchQueue.main.async { if case .downloading = self?.phase { self?.phase = .downloading(p.fractionCompleted) } }
        }
        task.resume()
    }
    private var observation: NSKeyValueObservation?

    private func fail(_ why: String) {
        DispatchQueue.main.async { self.phase = .failed(why); CrashLog.mark("Update: \(why)") }
    }

    private func verifyAndSwap(zip: URL, work: URL, info: ReleaseInfo) {
        // 1. Prüfsumme: genau die veröffentlichte Datei
        guard let data = try? Data(contentsOf: zip, options: .mappedIfSafe),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == info.sha256.lowercased() else {
            fail(L("Prüfsumme stimmt nicht – Update verworfen")); return
        }
        // 2. Entpacken
        let unz = Proc.zsh("/usr/bin/ditto -x -k \(Shell.quote(zip.path)) \(Shell.quote(work.path))", in: work.path, timeout: 300)
        let newApp = work.appendingPathComponent("Salenta Code.app")
        guard unz.code == 0, FileManager.default.fileExists(atPath: newApp.path) else { fail(L("Entpacken fehlgeschlagen")); return }
        // 3. Signatur gültig und vom selben Entwickler wie diese App
        let v = Proc.zsh("/usr/bin/codesign --verify --deep --strict \(Shell.quote(newApp.path))", in: work.path, timeout: 120)
        guard v.code == 0 else { fail(L("Signatur ungültig – Update verworfen")); return }
        let mine = Self.teamID(Bundle.main.bundleURL), theirs = Self.teamID(newApp)
        guard let theirs, theirs == mine else { fail(L("Update stammt nicht vom selben Entwickler – verworfen")); return }
        // 4. Selbsttest der neuen Version
        let t = Proc.zsh("\(Shell.quote(newApp.appendingPathComponent("Contents/MacOS/SalentaOS").path)) --selftest", in: work.path, timeout: 180)
        guard t.code == 0 else { fail(L("Selbsttest der neuen Version rot – bleibe bei der jetzigen")); return }
        // 5. Austauschen: jetzige Version aufheben, neue an ihren Platz, neu starten
        DispatchQueue.main.async { self.phase = .installing }
        let fm = FileManager.default
        let target = Bundle.main.bundleURL
        try? fm.removeItem(at: Self.previous)
        try? fm.createDirectory(at: Self.previous.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.moveItem(at: target, to: Self.previous)
            try fm.moveItem(at: newApp, to: target)
        } catch {
            if !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: Self.previous, to: target) }   // alles zurück
            fail(L("Austauschen fehlgeschlagen: ") + error.localizedDescription); return
        }
        _ = Proc.zsh("/usr/bin/xattr -dr com.apple.quarantine \(Shell.quote(target.path))", in: work.path, timeout: 30)
        CrashLog.mark("Update installiert: \(Self.current) → \(info.version)")
        try? fm.removeItem(at: work)
        DispatchQueue.main.async { Self.relaunch(target) }
    }

    /// Developer-Team aus der Signatur („TeamIdentifier=ABCDE12345“).
    static func teamID(_ app: URL) -> String? {
        let r = Proc.zsh("/usr/bin/codesign -dv \(Shell.quote(app.path)) 2>&1", in: NSTemporaryDirectory(), timeout: 30)
        guard let line = r.out.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }) else { return nil }
        let t = String(line.dropFirst("TeamIdentifier=".count))
        return t == "not set" ? nil : t
    }

    /// Neu starten: ein kleiner Helfer wartet, bis diese App weg ist, und öffnet die neue.
    static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "for i in {1..120}; do kill -0 \(pid) 2>/dev/null || break; sleep 0.5; done; open \(Shell.quote(app.path))"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", "nohup zsh -c \(Shell.quote(script)) >/dev/null 2>&1 &"]
        try? p.run()
        AppDelegate.terminating = true
        SafeStart.cleanExit()
        NSApp.terminate(nil)
    }

    /// Vorige Version zurückholen.
    func rollback() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.previous.path) else { return }
        let target = Bundle.main.bundleURL
        let tmp = Paths.support.appendingPathComponent("rollback-\(UUID().uuidString).app")
        do {
            try fm.moveItem(at: target, to: tmp)
            try fm.moveItem(at: Self.previous, to: target)
            try? fm.removeItem(at: tmp)
            Self.relaunch(target)
        } catch { phase = .failed(L("Zurückholen fehlgeschlagen")) }
    }
}

// MARK: - Einstellungen › Updates

struct UpdateSettings: View {
    @ObservedObject private var u = Updater.shared
    @AppStorage("update.auto") private var auto = true
    @AppStorage("update.beta") private var beta = false
    @State private var identities: [String] = []
    @State private var certHint = ""
    @State private var needsCA = false
    @State private var notary = false
    @State private var repoFile = ""

    var body: some View {
        Section("Updates") {
            LabeledContent(L("Version"), value: Updater.current + (Paths.isDevBuild ? " · " + L("Entwickler-Version") : ""))
            if Paths.isDevBuild {
                Text("Diese Version wird aus dem Quellcode gebaut und aktualisiert sich über „Salenta Code neu bauen“. Nutzer der fertigen App bekommen Updates automatisch.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if Updater.repo.isEmpty {
                Text("Keine Update-Quelle hinterlegt.").foregroundStyle(.secondary)
            } else {
                Toggle(L("Updates automatisch installieren (wenn keine Agents laufen)"), isOn: $auto)
                Toggle(L("Beta-Versionen bekommen"), isOn: $beta)
                HStack {
                    status
                    Spacer()
                    if let a = u.available {
                        Button(L("Jetzt auf ") + a.version) { u.install(force: true) }.buttonStyle(.borderedProminent)
                    }
                    Button(L("Nach Updates suchen")) { u.check(manual: true) }
                }
                if let n = u.available?.notes, !n.isEmpty { Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(8) }
                if FileManager.default.fileExists(atPath: Updater.previous.path) {
                    Button(L("Vorige Version zurückholen")) { u.rollback() }.controlSize(.small)
                }
            }
        }
        if Paths.isDevBuild { publishing }
    }

    @ViewBuilder private var status: some View {
        switch u.phase {
        case .idle: Text(u.available == nil ? (u.lastCheck.map { L("Aktuell – geprüft ") + $0.formatted(date: .omitted, time: .shortened) } ?? L("Noch nicht geprüft")) : L("Update bereit")).foregroundStyle(.secondary)
        case .checking: HStack { ProgressView().controlSize(.small); Text("Suche …") }
        case .downloading(let p): HStack { ProgressView(value: p).frame(width: 120); Text("\(Int(p * 100)) %").monospacedDigit() }
        case .verifying: HStack { ProgressView().controlSize(.small); Text("Prüfe Signatur und Selbsttest …") }
        case .waitingForAgents: Text("Wartet, bis die Agents fertig sind").foregroundStyle(.orange)
        case .installing: HStack { ProgressView().controlSize(.small); Text("Installiere – startet gleich neu") }
        case .failed(let why): Text(why).foregroundStyle(.red)
        }
    }

    /// Nur in der Entwickler-Version: was zum Veröffentlichen noch fehlt.
    private var publishing: some View {
        Section("Veröffentlichen (für dich als Entwickler)") {
            row(!identities.isEmpty, L("Developer-ID-Zertifikat"), identities.first ?? (certHint.isEmpty ? L("fehlt – developer.apple.com › Certificates › „Developer ID Application“") : certHint))
            if needsCA {
                Button(L("Apple-Zwischenzertifikat installieren")) {
                    Detection.runInTerminal("curl -fsSL https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer -o /tmp/DeveloperIDG2CA.cer && security import /tmp/DeveloperIDG2CA.cer -k ~/Library/Keychains/login.keychain-db ; echo '✓ Fertig – in Salenta Code auf „Erneut prüfen“ klicken'")
                }
            }
            row(notary, L("Notar-Zugang (Apple-Beglaubigung)"), notary ? "salenta-notary" : L("fehlt – einmal einrichten"))
            row(!repoFile.isEmpty, L("GitHub-Repo für Updates"), repoFile.isEmpty ? L("fehlt – z. B. salenta-code/salenta-code") : repoFile)
            HStack {
                if !notary {
                    Button(L("Notar-Zugang einrichten")) {
                        Detection.runInTerminal("xcrun notarytool store-credentials salenta-notary ; echo '✓ Fertig – zurück zu Salenta Code'")
                    }
                }
                Button(L("Erneut prüfen")) { load() }
                Spacer()
                Button(L("Version veröffentlichen …")) {
                    let a = NSAlert()
                    a.messageText = L("Neue Version veröffentlichen")
                    a.informativeText = L("Versionsnummer (jetzt ") + Updater.current + "):"
                    let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24)); f.stringValue = Self.bump(Updater.current)
                    a.accessoryView = f
                    a.addButton(withTitle: L("Veröffentlichen")); a.addButton(withTitle: L("Abbrechen"))
                    guard a.runModal() == .alertFirstButtonReturn else { return }
                    Detection.runInTerminal("cd \(Shell.quote(Paths.source.path)) && scripts/release.sh \(Shell.quote(f.stringValue))")
                }
                .buttonStyle(.borderedProminent)
                .disabled(identities.isEmpty || !notary || repoFile.isEmpty)
            }
        }
        .task { load() }
    }

    private func row(_ ok: Bool, _ title: String, _ detail: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }

    static func bump(_ v: String) -> String {
        var p = v.split(separator: "-")[0].split(separator: ".").map { Int($0) ?? 0 }
        while p.count < 3 { p.append(0) }
        p[1] += 1; p[2] = 0
        return p.map(String.init).joined(separator: ".")
    }

    private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let ids = Proc.zsh("security find-identity -v -p codesigning", in: NSTemporaryDirectory(), timeout: 15).out
                .split(separator: "\n").compactMap { l -> String? in
                    guard let a = l.range(of: "\"Developer ID Application: "), let b = l.range(of: "\"", options: .backwards), a.upperBound < b.lowerBound else { return nil }
                    return String(l[l.index(after: a.lowerBound)..<b.lowerBound])
                }
            // Warum fehlt es? Zertifikat ohne Schlüssel, nicht vertrauenswürdig (Zwischenzertifikat fehlt) oder gar nicht da.
            let tmp = NSTemporaryDirectory()
            let all = Proc.zsh("security find-identity -p codesigning", in: tmp, timeout: 15).out
            let devAll = all.split(separator: "\n").filter { $0.contains("Developer ID Application") }
            let certs = Proc.zsh("security find-certificate -a -c 'Developer ID Application' -p | grep -c 'BEGIN CERTIFICATE'", in: tmp, timeout: 15).out.trimmingCharacters(in: .whitespacesAndNewlines)
            let ca = Proc.zsh("security find-certificate -a -c 'Developer ID Certification Authority' -p | grep -c 'BEGIN CERTIFICATE'", in: tmp, timeout: 15).out.trimmingCharacters(in: .whitespacesAndNewlines)
            var hint = "", wantCA = false
            if ids.isEmpty {
                if let bad = devAll.first {
                    // Zertifikat + Schlüssel sind da, aber macOS vertraut der Kette nicht
                    let code = bad.contains("CSSMERR") ? (bad.split(separator: "(").last.map { String($0.dropLast()) } ?? "") : ""
                    if (Int(ca) ?? 0) == 0 || code.contains("NOT_TRUSTED") {
                        hint = L("vorhanden, aber macOS vertraut ihm noch nicht – das Apple-Zwischenzertifikat „Developer ID G2“ fehlt")
                        wantCA = true
                    } else {
                        hint = L("vorhanden, aber ungültig") + (code.isEmpty ? L(" (abgelaufen oder widerrufen?)") : ": " + code)
                    }
                } else if (Int(certs) ?? 0) > 0 {
                    hint = L("Zertifikat ist da, aber der private Schlüssel fehlt – es wurde nicht auf diesem Mac angefordert. Neu erstellen mit einer Zertifikatsanfrage aus der Schlüsselbundverwaltung dieses Macs.")
                } else {
                    hint = L("nicht im Schlüsselbund – .cer herunterladen und doppelklicken (Schlüsselbund „Anmeldung“)")
                }
            }
            let diag = "find-identity:\n\(all)\nDeveloperID-Zertifikate: \(certs)\nZwischenzertifikat: \(ca)\nHinweis: \(hint)\n"
            try? diag.write(to: Paths.root.appendingPathComponent("logs/devid-check.txt"), atomically: true, encoding: .utf8)
            let n = Proc.zsh("xcrun notarytool history --keychain-profile salenta-notary >/dev/null 2>&1", in: NSTemporaryDirectory(), timeout: 40).code == 0
            let repo = (try? String(contentsOf: Paths.source.appendingPathComponent("UPDATE_REPO"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async { identities = ids; notary = n; repoFile = repo; certHint = hint; needsCA = wantCA }
        }
    }
}
