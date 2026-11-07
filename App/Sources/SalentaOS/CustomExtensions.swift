import AgenticOSKit
import AppKit
import SwiftUI

// Eigene Erweiterungen: beliebige GitHub-Repos hinzufügen – per Link oder über die Suche.
// Salenta Code schaut ins Repo, erkennt die Art (Claude-Plugin, Skill, MCP-Server) und baut den passenden Installationsbefehl.

/// Gespeicherte, selbst hinzugefügte Erweiterung.
struct CustomExtension: Codable, Hashable, Identifiable {
    var id: String          // "custom:owner/repo[:plugin]"
    var name: String
    var kind: String        // Extension.Kind.rawValue
    var repo: String        // https://github.com/owner/repo
    var stars: Int
    var purpose: String
    var install: String
    var keywords: [String]

    var asExtension: Extension {
        Extension(id: id, name: name, kind: Extension.Kind(rawValue: kind) ?? .tool, category: .essentials,
                  repo: repo, stars: stars > 0 ? "★ \(stars) · " + L("von dir hinzugefügt") : L("von dir hinzugefügt"),
                  purpose: purpose.isEmpty ? L("Ohne Beschreibung im Repo.") : purpose,
                  when: keywords, install: install, usage: "")
    }
}

final class CustomExtensions: ObservableObject {
    static let shared = CustomExtensions()
    @Published private(set) var items: [CustomExtension] = []
    private var url: URL { Paths.root.appendingPathComponent("data/custom-extensions.json") }

    init() {
        if let d = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([CustomExtension].self, from: d) { items = list }
    }

    var extensions: [Extension] { items.map(\.asExtension) }

    func add(_ list: [CustomExtension]) {
        for e in list where !items.contains(where: { $0.id == e.id }) { items.append(e) }
        save()
    }

    func remove(_ id: String) { items.removeAll { $0.id == id }; save() }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: url, options: .atomic) }
        objectWillChange.send()
        ExtensionStore.shared.refresh()
    }
}

/// GitHub lesen – mit „gh“, wenn angemeldet (höheres Limit), sonst über die offene API.
enum GitHubRead {
    static func json(_ path: String) -> Any? {
        let out: String
        if Detection.which("gh") != nil, Proc.zsh("gh auth status", in: NSTemporaryDirectory(), timeout: 8).code == 0 {
            out = Proc.zsh("gh api " + Shell.quote(path), in: NSTemporaryDirectory(), timeout: 25).out
        } else {
            out = Proc.zsh("curl -fsSL -H 'Accept: application/vnd.github+json' " + Shell.quote("https://api.github.com/" + path),
                           in: NSTemporaryDirectory(), timeout: 25).out
        }
        return try? JSONSerialization.jsonObject(with: Data(out.utf8))
    }

    static func file(_ repo: String, _ path: String) -> String? {
        guard let j = json("repos/\(repo)/contents/\(path)") as? [String: Any],
              let b64 = j["content"] as? String,
              let d = Data(base64Encoded: b64.replacingOccurrences(of: "\n", with: "")) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    /// „owner/repo“ aus Link oder Kurzform
    static func slug(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://", "http://", "www.", "github.com/"] where t.lowercased().hasPrefix(p) { t = String(t.dropFirst(p.count)) }
        if t.lowercased().hasPrefix("github.com/") { t = String(t.dropFirst(11)) }
        t = t.replacingOccurrences(of: ".git", with: "")
        let parts = t.split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts[0].unicodeScalars.allSatisfy(ok.contains), parts[1].unicodeScalars.allSatisfy(ok.contains) else { return nil }
        return parts[0] + "/" + parts[1]
    }
}

/// Schaut ins Repo und erkennt, was es ist.
enum RepoInspector {
    /// Einfache Namen ohne Anführungszeichen (damit Salenta Code später erkennt, ob es installiert ist), alles andere sicher quoten.
    static func arg(_ x: String) -> String {
        x.range(of: #"^[A-Za-z0-9._@/-]+$"#, options: .regularExpression) != nil ? x : Shell.quote(x)
    }
    struct Result { var items: [CustomExtension]; var note: String }

    static func inspect(_ raw: String) -> Result {
        guard let slug = GitHubRead.slug(raw) else { return Result(items: [], note: L("Das sieht nicht wie ein GitHub-Repo aus. Beispiel: github.com/owner/repo")) }
        guard let meta = GitHubRead.json("repos/\(slug)") as? [String: Any], meta["full_name"] != nil else {
            return Result(items: [], note: String(format: L("Repo „%@“ nicht gefunden (oder privat)."), slug))
        }
        let desc = (meta["description"] as? String) ?? ""
        let stars = meta["stargazers_count"] as? Int ?? 0
        let topics = (meta["topics"] as? [String]) ?? []
        let url = "https://github.com/\(slug)"
        let repoName = String(slug.split(separator: "/").last ?? "")
        let keywords = Array(Set(topics + repoName.lowercased().split(separator: "-").map(String.init))).filter { $0.count >= 3 }
        func item(_ suffix: String, _ name: String, _ kind: Extension.Kind, _ install: String, _ purpose: String = desc) -> CustomExtension {
            CustomExtension(id: "custom:\(slug)\(suffix)", name: name, kind: kind.rawValue, repo: url, stars: stars,
                            purpose: purpose, install: install, keywords: keywords)
        }

        // 1. Claude-Plugin-Marktplatz
        if let mp = GitHubRead.file(slug, ".claude-plugin/marketplace.json"),
           let j = try? JSONSerialization.jsonObject(with: Data(mp.utf8)) as? [String: Any] {
            let market = (j["name"] as? String) ?? repoName
            let plugins = ((j["plugins"] as? [[String: Any]]) ?? []).prefix(12)
            let add = "claude plugin marketplace add \(Shell.quote(slug))"
            let list = plugins.compactMap { p -> CustomExtension? in
                guard let n = p["name"] as? String, !n.isEmpty else { return nil }
                return item(":\(n)", n, .plugin, "(claude plugin marketplace list 2>/dev/null | grep -q \(arg(market)) || \(add)); claude plugin install \(arg(n + "@" + market))",
                            (p["description"] as? String) ?? desc)
            }
            if !list.isEmpty { return Result(items: list, note: String(format: L("Claude-Plugin-Marktplatz mit %d Plugin(s) erkannt."), list.count)) }
        }

        // 2. Skills (SKILL.md im Repo oder unter skills/<name>/)
        var skillDirs: [String] = []
        if GitHubRead.file(slug, "SKILL.md") != nil { skillDirs = ["."] }
        else if let arr = GitHubRead.json("repos/\(slug)/contents/skills") as? [[String: Any]] {
            skillDirs = arr.filter { ($0["type"] as? String) == "dir" }.compactMap { $0["name"] as? String }.map { "skills/" + $0 }.prefix(12).map { $0 }
        }
        if !skillDirs.isEmpty {
            let tmp = "/tmp/sc-skill-\(repoName)"
            let list = skillDirs.map { dir -> CustomExtension in
                let n = dir == "." ? repoName : String(dir.split(separator: "/").last ?? "")
                let cmd = "rm -rf \(Shell.quote(tmp)) && git clone -q --depth 1 \(Shell.quote(url + ".git")) \(Shell.quote(tmp)) && mkdir -p ~/.claude/skills && rm -rf ~/.claude/skills/\(Shell.quote(n)) && cp -R \(Shell.quote(tmp + "/" + dir)) ~/.claude/skills/\(Shell.quote(n)) && rm -rf \(Shell.quote(tmp))"
                return item(dir == "." ? "" : ":\(n)", n, .skill, cmd)
            }
            return Result(items: list, note: String(format: L("%d Skill(s) erkannt – werden nach ~/.claude/skills kopiert."), list.count))
        }

        // 3. MCP-Server (npm oder Python)
        let looksMCP = topics.contains { $0.contains("mcp") } || repoName.lowercased().contains("mcp") || desc.lowercased().contains("mcp")
        if let pkg = GitHubRead.file(slug, "package.json"),
           let j = try? JSONSerialization.jsonObject(with: Data(pkg.utf8)) as? [String: Any],
           let npm = j["name"] as? String, looksMCP || pkg.contains("@modelcontextprotocol/sdk") {
            let short = npm.split(separator: "/").last.map(String.init) ?? npm
            return Result(items: [item("", short, .mcp, "claude mcp add --scope user \(arg(short)) -- npx -y \(arg(npm))")],
                          note: L("MCP-Server (npm) erkannt – wird für Claude Code eingetragen."))
        }
        if looksMCP, let py = GitHubRead.file(slug, "pyproject.toml"),
           let m = py.range(of: #"name\s*=\s*"([^"]+)""#, options: .regularExpression) {
            let name = String(py[m]).components(separatedBy: "\"")[1]
            return Result(items: [item("", name, .mcp, "claude mcp add --scope user \(arg(name)) -- uvx \(arg(name))")],
                          note: L("MCP-Server (Python) erkannt – wird für Claude Code eingetragen."))
        }

        // 4. Unbekannt: als Werkzeug mit Anleitung merken
        return Result(items: [item("", repoName, .tool, "open " + url)],
                      note: L("Keine automatische Installation erkannt – gespeichert mit Link zur Anleitung im Repo."))
    }
}

/// Suche über GitHub nach passenden Repos (Plugins, Skills, MCP-Server).
enum GitHubSearch {
    struct Hit: Identifiable, Hashable { let id: String; let description: String; let stars: Int }

    static func search(_ q: String) -> [Hit] {
        let base = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard base.count >= 2 else { return [] }
        // Breit suchen, aber auf Agent-Werkzeuge ausrichten
        var hits: [Hit] = []
        for extra in ["claude code", "mcp", ""] {
            let query = (base + (extra.isEmpty ? "" : " " + extra)).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? base
            guard let j = GitHubRead.json("search/repositories?q=\(query)&sort=stars&per_page=12") as? [String: Any],
                  let arr = j["items"] as? [[String: Any]] else { continue }
            for r in arr {
                guard let n = r["full_name"] as? String, !hits.contains(where: { $0.id == n }) else { continue }
                hits.append(Hit(id: n, description: (r["description"] as? String) ?? "", stars: r["stargazers_count"] as? Int ?? 0))
            }
            if hits.count >= 20 { break }
        }
        return Array(hits.sorted { $0.stars > $1.stars }.prefix(20))
    }
}

/// Suchfeld + „Repo hinzufügen“ oben auf der Seite „Erweiterungen“.
struct ExtensionSearchBar: View {
    @Binding var filter: String
    @ObservedObject private var custom = CustomExtensions.shared
    @State private var hits: [GitHubSearch.Hit] = []
    @State private var searching = false
    @State private var adding: String? = nil
    @State private var message: String? = nil
    @State private var showAdd = false
    @State private var link = ""

    static func matches(_ e: Extension, _ f: String) -> Bool {
        let t = f.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return true }
        return ([e.name, e.purpose, e.repo, e.kind.rawValue] + e.when).contains { $0.lowercased().contains(t) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.s) {
            HStack(spacing: Grid.s) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("Erweiterungen suchen – oder auf GitHub, z. B. „supabase“, „figma“, „tests“"), text: $filter)
                        .textFieldStyle(.plain)
                        .onSubmit { searchGitHub() }
                    if !filter.isEmpty {
                        Button { filter = ""; hits = []; message = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.tertiary).help(L("Suche leeren"))
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(ModernCardBackground(radius: 9, accent: false))
                Button { searchGitHub() } label: { Label(L("Auf GitHub suchen"), systemImage: "globe") }
                    .disabled(filter.trimmingCharacters(in: .whitespaces).count < 2 || searching)
                    .help(L("Öffentliche GitHub-Repos zu diesem Suchwort finden (Plugins, Skills, MCP-Server)"))
                Button { showAdd = true } label: { Label(L("Repo hinzufügen …"), systemImage: "plus") }
                    .help(L("Ein beliebiges GitHub-Repo per Link hinzufügen – Salenta Code erkennt, wie es installiert wird"))
            }
            if let m = message { Text(m).font(.caption).foregroundStyle(.secondary) }
            if searching { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Suche auf GitHub …").font(.caption).foregroundStyle(.secondary) } }
            if !hits.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(String(format: L("%d Treffer auf GitHub"), hits.count)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Ausblenden")) { hits = [] }.buttonStyle(.link).font(.caption)
                    }.padding(.bottom, 4)
                    ForEach(hits) { h in
                        let known = custom.items.contains { $0.repo.lowercased() == "https://github.com/\(h.id)".lowercased() }
                            || ExtensionCatalog.curated.contains { $0.repo.lowercased().contains(h.id.lowercased()) }
                        Divider().opacity(0.4)
                        HStack(alignment: .top, spacing: Grid.s) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(h.id).font(.callout.weight(.medium))
                                    Text("★ \(h.stars)").font(.caption2).foregroundStyle(.tertiary)
                                }
                                if !h.description.isEmpty { Text(h.description).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            }
                            Spacer()
                            if let u = URL(string: "https://github.com/\(h.id)") {
                                Link(destination: u) { Image(systemName: "arrow.up.right.square") }.help(L("Repo auf GitHub ansehen"))
                            }
                            if known {
                                Label(L("schon da"), systemImage: "checkmark").font(.caption).foregroundStyle(.green)
                            } else if adding == h.id {
                                ProgressView().controlSize(.small)
                            } else {
                                Button(L("Hinzufügen")) { add(h.id) }.controlSize(.small)
                                    .help(L("Repo prüfen und zu deinen Erweiterungen legen – installiert wird erst, wenn du auf „Installieren“ klickst"))
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                .padding(Grid.m)
                .background(ModernCardBackground(radius: 12))
            }
        }
        .sheet(isPresented: $showAdd) {
            VStack(alignment: .leading, spacing: Grid.m) {
                Text("Repo hinzufügen").font(.title3.weight(.semibold))
                Text("Link zu einem öffentlichen GitHub-Repo. Salenta Code erkennt Claude-Plugins, Skills und MCP-Server und baut den Installationsbefehl. Installiert wird erst, wenn du auf der Karte „Installieren“ klickst.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("https://github.com/owner/repo", text: $link).textFieldStyle(.roundedBorder).onSubmit { submitLink() }
                Text("Nur Repos hinzufügen, denen du vertraust – Erweiterungen laufen mit deinen Rechten auf deinem Mac.")
                    .font(.caption).foregroundStyle(.tertiary)
                HStack {
                    Spacer()
                    Button(L("Abbrechen")) { showAdd = false; link = "" }
                    Button(L("Hinzufügen")) { submitLink() }
                        .buttonStyle(.borderedProminent).disabled(GitHubRead.slug(link) == nil)
                }
            }
            .padding(Grid.xl).frame(width: 520)
        }
    }

    private func submitLink() {
        guard let slug = GitHubRead.slug(link) else { return }
        showAdd = false; link = ""
        add(slug)
    }

    private func searchGitHub() {
        let q = filter
        guard q.trimmingCharacters(in: .whitespaces).count >= 2 else { return }
        searching = true; message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let r = GitHubSearch.search(q)
            DispatchQueue.main.async {
                searching = false; hits = r
                if r.isEmpty { message = L("Nichts auf GitHub gefunden – anderes Suchwort probieren.") }
            }
        }
    }

    private func add(_ slug: String) {
        adding = slug; message = String(format: L("Prüfe %@ …"), slug)
        DispatchQueue.global(qos: .userInitiated).async {
            let r = RepoInspector.inspect(slug)
            DispatchQueue.main.async {
                adding = nil
                custom.add(r.items)
                message = (r.items.isEmpty ? "" : "✓ \(slug): ") + r.note + (r.items.isEmpty ? "" : " " + L("Unter „Von dir hinzugefügt“ installieren."))
            }
        }
    }
}
