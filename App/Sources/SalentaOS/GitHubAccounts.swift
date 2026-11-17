import AgenticOSKit
import SwiftUI

// GitHub-Konten: sehen, welches Konto aktiv ist, zwischen mehreren angemeldeten Konten wechseln, abmelden und ein weiteres
// anmelden. Alles läuft über die GitHub-CLI (gh) – Tokens bleiben in ihrem Schlüsselbund, Salenta Code sieht sie nie.

enum GitHubAccounts {
    struct Account: Hashable, Identifiable { let host: String; let user: String; let active: Bool; var id: String { host + "/" + user } }

    /// Aus der Ausgabe von `gh auth status`: je Host die angemeldeten Konten und welches aktiv ist.
    static func parse(_ text: String) -> [Account] {
        var out: [Account] = []
        var host = "github.com"
        var pending: (host: String, user: String)?
        func flush(active: Bool) { if let p = pending { out.append(Account(host: p.host, user: p.user, active: active)); pending = nil } }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty, !raw.hasPrefix(" "), !line.contains(" "), line.contains(".") { flush(active: false); host = line; continue }
            if let r = line.range(of: #"account ([A-Za-z0-9-]+)"#, options: .regularExpression), line.lowercased().contains("logged in") {
                flush(active: false)
                pending = (host, String(line[r].dropFirst("account ".count)))
                continue
            }
            if line.lowercased().hasPrefix("- active account:") { flush(active: line.lowercased().hasSuffix("true")) }
        }
        flush(active: out.isEmpty)
        return out
    }

    static func list() -> [Account] {
        guard Detection.which("gh") != nil else { return [] }
        let r = Proc.zsh("gh auth status 2>&1", in: NSTemporaryDirectory(), timeout: 20)
        return parse(r.out)
    }

    /// Nur ein harmloser Konto-Name (GitHub erlaubt Buchstaben, Ziffern und Bindestriche).
    static func safe(_ s: String) -> Bool { s.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}$"#, options: .regularExpression) != nil }
    static func safeHost(_ s: String) -> Bool { s.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil }

    static func switchTo(_ a: Account) -> Bool {
        guard safe(a.user), safeHost(a.host) else { return false }
        let ok = Proc.zsh("gh auth switch -h \(a.host) -u \(a.user) 2>&1", in: NSTemporaryDirectory(), timeout: 20).code == 0
        GH.invalidate()
        return ok
    }
    static func logoutCommand(_ a: Account) -> String? {
        guard safe(a.user), safeHost(a.host) else { return nil }
        return "gh auth logout -h \(a.host) -u \(a.user)"
    }
    static let loginCommand = "gh auth login -h github.com -w && gh auth setup-git"
}

/// Einstellungen › Allgemein: GitHub-Konten.
struct GitHubAccountsSection: View {
    @State private var accounts: [GitHubAccounts.Account] = []
    @State private var loading = true
    @State private var note: String?

    var body: some View {
        Section("GitHub") {
            if Detection.which("gh") == nil {
                Text("Die GitHub-CLI fehlt – im Terminal: brew install gh").font(.caption).foregroundStyle(.orange)
            } else if loading {
                ProgressView().controlSize(.small)
            } else if accounts.isEmpty {
                Text("Kein GitHub-Konto angemeldet.").foregroundStyle(.secondary)
            } else {
                ForEach(accounts) { a in
                    HStack(spacing: 8) {
                        Image(systemName: a.active ? "checkmark.circle.fill" : "person.crop.circle").foregroundStyle(a.active ? .green : .secondary)
                        Text(a.user).fontWeight(a.active ? .semibold : .regular)
                        if a.host != "github.com" { Text(a.host).font(.caption).foregroundStyle(.secondary) }
                        if a.active { Text("aktiv").font(.caption2).foregroundStyle(.secondary) }
                        Spacer()
                        if !a.active {
                            Button("Verwenden") {
                                DispatchQueue.global(qos: .userInitiated).async {
                                    let ok = GitHubAccounts.switchTo(a)
                                    DispatchQueue.main.async { note = ok ? String(format: L("%@ ist jetzt aktiv."), a.user) : L("Wechsel hat nicht geklappt – im Terminal: gh auth switch"); reload() }
                                }
                            }.controlSize(.small)
                            .help(L("Pull Requests, Reviews und Pushes laufen ab jetzt über dieses Konto"))
                        }
                        if let cmd = GitHubAccounts.logoutCommand(a) {
                            Button("Abmelden", role: .destructive) { Detection.runInTerminal(cmd); GH.invalidate(); reloadLater() }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                }
            }
            HStack {
                Button(accounts.isEmpty ? L("Bei GitHub anmelden") : L("Weiteres Konto anmelden")) {
                    Detection.runInTerminal(GitHubAccounts.loginCommand); GH.invalidate(); reloadLater()
                }
                Spacer()
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help(L("Aktualisieren"))
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            Text("Mehrere Konten (z. B. privat und Firma) können gleichzeitig angemeldet sein – das aktive nutzt Salenta Code für Pull Requests, Reviews und Pushes. Die Anmeldung läuft im Browser; Tokens bleiben bei der GitHub-CLI.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { reload() }
    }

    private func reload() {
        loading = accounts.isEmpty
        DispatchQueue.global(qos: .utility).async {
            let a = GitHubAccounts.list()
            DispatchQueue.main.async { accounts = a; loading = false }
        }
    }
    /// Nach Anmelden/Abmelden im Terminal ein paar Mal nachsehen
    private func reloadLater() {
        for s in [5.0, 15, 40, 90] { DispatchQueue.main.asyncAfter(deadline: .now() + s) { reload() } }
    }
}
