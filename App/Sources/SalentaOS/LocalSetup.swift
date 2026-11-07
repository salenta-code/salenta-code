import AgenticOSKit
import AppKit
import Metal
import SwiftUI

// Lokale Modelle ohne Terminal: Salenta Code installiert Ollama selbst (offizielle DMG, Signatur geprüft),
// startet den Ollama-Dienst mit der App, wählt ein Modell, das in den Grafikspeicher dieses Macs passt,
// lädt es (nur am Netzteil) und aktiviert es. Alles sichtbar in Einstellungen › Modelle.

enum OllamaApp {
    static let downloadURL = URL(string: "https://ollama.com/download/Ollama.dmg")!

    static var appPath: String? {
        ["/Applications/Ollama.app", NSHomeDirectory() + "/Applications/Ollama.app"].first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Befehl `ollama` – aus dem PATH oder direkt aus der App (ohne Symlink in /usr/local/bin).
    static var binary: String? {
        if let w = Detection.which("ollama") { return w }
        if let a = appPath {
            let b = a + "/Contents/Resources/ollama"
            if FileManager.default.isExecutableFile(atPath: b) { return b }
        }
        return nil
    }
    static var installed: Bool { binary != nil }
    /// Für Shell-Befehle: `ollama` mit vollem Pfad, falls nicht im PATH.
    static var cli: String { binary.map(Shell.quote) ?? "ollama" }

    /// Läuft der Dienst? (kurzer, lokaler Aufruf)
    static func serverUp() -> Bool {
        var ok = false
        let sem = DispatchSemaphore(value: 0)
        var r = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/version")!, timeoutInterval: 2)
        r.httpMethod = "GET"
        URLSession.shared.dataTask(with: r) { _, resp, _ in ok = (resp as? HTTPURLResponse)?.statusCode == 200; sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 3)
        return ok
    }

    /// Dienst starten (unsichtbar im Hintergrund) und bis zu 15 s warten.
    @discardableResult
    static func startServer() -> Bool {
        if serverUp() { return true }
        if let a = appPath {
            _ = Proc.zsh("open -gja \(Shell.quote(a))", in: NSTemporaryDirectory(), timeout: 10)
        } else if let b = binary {
            _ = Proc.zsh("OLLAMA_CONTEXT_LENGTH=\(LocalFirst.contextSize) nohup \(Shell.quote(b)) serve >/dev/null 2>&1 &", in: NSTemporaryDirectory(), timeout: 10)
        } else { return false }
        for _ in 0..<15 { if serverUp() { return true }; Thread.sleep(forTimeInterval: 1) }
        return serverUp()
    }

    /// Installierte Modelle über die Schnittstelle (ohne CLI).
    static func models() -> [String] {
        guard serverUp() else { return [] }
        var out: [String] = []
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:11434/api/tags")!) { d, _, _ in
            if let d, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let list = j["models"] as? [[String: Any]] {
                out = list.compactMap { $0["name"] as? String }
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 5)
        return out
    }

    /// Offizielle App laden, Signatur prüfen, nach ~/Applications kopieren. Gibt einen Fehlertext zurück oder nil.
    static func install() -> String? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ollama-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dmg = tmp.appendingPathComponent("Ollama.dmg").path, mnt = tmp.appendingPathComponent("mnt").path
        let dl = Proc.zsh("curl -fsSL --retry 2 -o \(Shell.quote(dmg)) \(downloadURL.absoluteString)", in: tmp.path, timeout: 900)
        guard dl.code == 0 else { return L("Download von ollama.com fehlgeschlagen") }
        let at = Proc.zsh("hdiutil attach -nobrowse -readonly -noautoopen -mountpoint \(Shell.quote(mnt)) \(Shell.quote(dmg))", in: tmp.path, timeout: 120)
        guard at.code == 0 else { return L("Installationsdatei ließ sich nicht öffnen") }
        defer { _ = Proc.zsh("hdiutil detach -quiet \(Shell.quote(mnt))", in: tmp.path, timeout: 60) }
        let src = mnt + "/Ollama.app"
        // Nur echte, von Apple beglaubigte Ollama-App installieren
        let sig = Proc.zsh("codesign --verify --deep --strict \(Shell.quote(src)) && spctl --assess --type execute \(Shell.quote(src)) && codesign -dv \(Shell.quote(src)) 2>&1 | grep -i 'Authority=Developer ID Application'",
                           in: tmp.path, timeout: 120)
        guard sig.code == 0 else { return L("Signatur der Ollama-App ist nicht gültig – nicht installiert") }
        let canSystem = FileManager.default.isWritableFile(atPath: "/Applications")
        let destDir = canSystem ? "/Applications" : NSHomeDirectory() + "/Applications"
        try? FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        let cp = Proc.zsh("ditto \(Shell.quote(src)) \(Shell.quote(destDir + "/Ollama.app"))", in: tmp.path, timeout: 300)
        guard cp.code == 0 else { return L("Kopieren nach Programme fehlgeschlagen") }
        Detection.forget("ollama")
        return nil
    }

    /// Grafikspeicher, den macOS für Modelle freigibt (GB). Auf Apple-Chips der entscheidende Wert.
    static var gpuGB: Double {
        if let d = MTLCreateSystemDefaultDevice() { return Double(d.recommendedMaxWorkingSetSize) / 1_073_741_824 }
        return Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 * 0.7
    }
}

/// Automatische Einrichtung beim Start von Salenta Code.
final class LocalSetup: ObservableObject {
    static let shared = LocalSetup()
    enum Phase: Equatable { case idle, installing, starting, pulling(String), ready, failed(String) }
    @Published private(set) var phase: Phase = .idle

    /// Ab Werk an: Salenta Code richtet lokale Modelle selbst ein.
    var auto: Bool { UserDefaults.standard.object(forKey: "local.autoSetup") as? Bool ?? true }

    /// Beim App-Start: Dienst hochfahren; fehlt etwas, nur am Netzteil und mit Internet nachholen.
    func boot() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.run(manual: false) }
    }

    func run(manual: Bool) {
        guard manual || auto else { return }
        if phase == .installing || phase == .starting { return }
        if case .pulling = phase { return }
        DispatchQueue.global(qos: .utility).async {
            // 1. Ollama selbst
            if !OllamaApp.installed {
                guard manual || (!Energy.saving && LocalFirst.shared.isOnline && UserDefaults.standard.object(forKey: "local.autoInstallApp") as? Bool ?? true) else { return }
                self.set(.installing)
                if let e = OllamaApp.install() { self.set(.failed(e)); return }
                CrashLog.mark("Ollama installiert")
            }
            // 2. Dienst starten
            self.set(.starting)
            guard OllamaApp.startServer() else { self.set(.failed(L("Ollama-Dienst startet nicht"))); return }
            DispatchQueue.main.async { LocalFirst.shared.loadModels() }
            // 3. Modell: fehlt eins, das passende laden (groß – nur am Netzteil, außer du startest es selbst)
            let have = OllamaApp.models().filter { !$0.contains("-sc:") }
            if have.isEmpty {
                guard let m = LocalCatalog.shared.recommendedForThisMac else { self.set(.failed(L("Kein passendes Modell für diesen Mac"))); return }
                guard manual || (!Energy.saving && LocalFirst.shared.isOnline) else { self.set(.idle); return }
                self.set(.pulling(m.pull))
                DispatchQueue.main.async {
                    LocalCatalog.shared.pull(m.pull)
                    Notifier.push("Salenta Code", L("Lokales Modell wird eingerichtet: ") + m.name + " (≈\(m.size) GB)", priority: 2, tags: "arrow_down")
                }
                return
            }
            self.set(.ready)
        }
    }

    fileprivate func pullFinished(ok: Bool, _ error: String?) {
        if ok { set(.ready) } else if let error { set(.failed(error)) }
    }

    private func set(_ p: Phase) { DispatchQueue.main.async { self.phase = p } }

    var text: String {
        switch phase {
        case .idle: return OllamaApp.installed ? L("Ollama ist installiert") : L("Ollama ist noch nicht installiert")
        case .installing: return L("Ollama wird installiert …")
        case .starting: return L("Ollama-Dienst startet …")
        case .pulling(let m): return L("Modell wird geladen: ") + m
        case .ready: return L("Lokal bereit – Ollama läuft mit Salenta Code")
        case .failed(let e): return e
        }
    }
}

extension LocalCatalog {
    /// Passt das Modell in den Grafikspeicher? (Modell + Platz für den Kontext)
    static func fitsGPU(_ m: LocalModelInfo) -> Bool { Double(m.size) + 2.5 <= OllamaApp.gpuGB }
    /// Passt bequem – lässt Luft für macOS und läuft kühler.
    static func comfortable(_ m: LocalModelInfo) -> Bool { Double(m.size) <= OllamaApp.gpuGB * 0.75 }

    /// Empfehlung für diesen Mac: das stärkste Modell, das bequem passt (sonst das stärkste, das überhaupt passt).
    var recommendedForThisMac: LocalModelInfo? {
        let ok = models.filter { $0.macIssue != true }
        return ok.filter(Self.comfortable).max { $0.rank < $1.rank } ?? ok.filter(Self.fitsGPU).max { $0.rank < $1.rank }
    }

    func notifySetup(ok: Bool, error: String?) { LocalSetup.shared.pullFinishedPublic(ok: ok, error) }
}

extension LocalSetup {
    func pullFinishedPublic(ok: Bool, _ error: String?) { pullFinished(ok: ok, error) }
}

/// Status und ein Knopf – ersetzt jede Terminal-Anleitung für lokale Modelle.
struct LocalSetupRow: View {
    @ObservedObject private var setup = LocalSetup.shared
    @ObservedObject private var catalog = LocalCatalog.shared
    @ObservedObject private var local = LocalFirst.shared
    @AppStorage("local.autoSetup") private var auto = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Grid.s) {
                icon
                Text(statusText).font(.callout)
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                } else if !OllamaApp.installed {
                    Button(L("Ollama installieren")) { setup.run(manual: true) }
                        .help(L("Lädt die offizielle Ollama-App von ollama.com, prüft die Apple-Signatur und richtet sie ein – ohne Terminal"))
                } else if local.models.isEmpty, let m = catalog.recommendedForThisMac {
                    Button(L("Empfohlenes Modell laden") + " (\(m.name), ≈\(m.size) GB)") { setup.run(manual: true) }
                } else if case .failed = setup.phase {
                    Button(L("Ollama starten")) { setup.run(manual: true) }
                }
            }
            if case .pulling(let m) = setup.phase, let p = catalog.pulling[m] {
                ProgressView(value: p) { Text("\(Int(p * 100)) %").font(.caption.monospacedDigit()) }
            }
            Toggle(L("Automatisch einrichten: Ollama installieren, mit Salenta Code starten und ein passendes Modell laden (große Downloads nur am Netzteil)"), isOn: $auto)
                .font(.caption)
        }
    }

    private var busy: Bool {
        switch setup.phase { case .installing, .starting: return true; case .pulling: return catalog.pulling.isEmpty; default: return false }
    }

    private var statusText: String {
        if case .idle = setup.phase, OllamaApp.installed, !local.models.isEmpty {
            return L("Lokal bereit") + (local.model.map { ": " + $0 } ?? "")
        }
        return setup.text
    }

    @ViewBuilder private var icon: some View {
        switch setup.phase {
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        default: Image(systemName: OllamaApp.installed ? "checkmark.circle" : "circle.dashed").foregroundStyle(OllamaApp.installed ? .green : .secondary)
        }
    }
}
