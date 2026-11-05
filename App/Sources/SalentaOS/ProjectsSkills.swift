import AgenticOSKit
import AppKit
import SwiftUI

// Projekte/Repos und Skills als Auswahl im Auftragsfeld.

struct Project: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let source: String
    let isGit: Bool
}

struct RemoteRepo: Identifiable, Hashable {
    var id: String { fullName }
    let fullName: String
    let url: String
    let updated: String
}

final class ProjectCatalog: ObservableObject {
    /// Deine Projekte – nur die, die du selbst hinzugefügt hast (Ordner, GitHub oder neu angelegt).
    @Published var local: [Project] = []
    @Published var github: [RemoteRepo] = []
    @Published var githubError: String?
    @Published var loadingGitHub = false

    private struct Saved: Codable { var path: String; var source: String }
    private var url: URL { Paths.data.appendingPathComponent("projects.json") }

    init() { reload() }

    func reload() {
        DispatchQueue.global(qos: .utility).async {
            let list = self.loadSaved()
            DispatchQueue.main.async { self.local = list }
        }
    }

    private func loadSaved() -> [Project] {
        let fm = FileManager.default
        var saved: [Saved]
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode([Saved].self, from: d) {
            saved = s
        } else {
            // Erster Start nach dem Umbau: Projekte übernehmen, in denen schon Aufträge liefen – nicht alles Gefundene
            var seen = Set<String>()
            saved = []
            for m in MissionStore.shared.missions.reversed() {
                let dir = m.worktree?.base ?? m.directory
                guard !dir.contains("/worktrees/"), fm.fileExists(atPath: dir + "/.git"), seen.insert(dir).inserted else { continue }
                saved.append(Saved(path: dir, source: "Ordner"))
            }
            if let d = try? JSONEncoder().encode(saved) { try? d.write(to: url, options: .atomic) }
        }
        return saved.compactMap { s in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: s.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return Project(path: s.path, name: (s.path as NSString).lastPathComponent, source: s.source,
                           isGit: fm.fileExists(atPath: (s.path as NSString).appendingPathComponent(".git")))
        }
    }

    private func persist() {
        let s = local.map { Saved(path: $0.path, source: $0.source) }
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: url, options: .atomic) }
    }

    func add(_ path: String, source: String) {
        guard !local.contains(where: { $0.path == path }) else { return }
        let git = FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
        local.insert(Project(path: path, name: (path as NSString).lastPathComponent, source: source, isGit: git), at: 0)
        persist()
    }

    func remove(_ path: String) { local.removeAll { $0.path == path }; persist() }

    /// Repos auf dem Mac, die (noch) nicht in der Liste sind – nur als Vorschlag beim Hinzufügen.
    func suggestions() -> [Project] {
        let have = Set(local.map(\.path))
        return Self.scanLocal().filter { $0.isGit && !have.contains($0.path) && !$0.path.contains("/worktrees/") }
    }

    /// GitHub-Repo klonen und als Projekt hinzufügen.
    func clone(_ repo: RemoteRepo, into base: String, completion: @escaping (_ path: String?, _ error: String?) -> Void) {
        let target = (base as NSString).appendingPathComponent(repo.fullName.components(separatedBy: "/").last ?? repo.fullName)
        if FileManager.default.fileExists(atPath: target + "/.git") { add(target, source: "GitHub"); completion(target, nil); return }
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
            let r = Proc.zsh("gh repo clone \(Shell.quote(repo.fullName)) \(Shell.quote(target))", in: base, timeout: 900)
            DispatchQueue.main.async {
                if r.code == 0 { self.add(target, source: "GitHub"); completion(target, nil) }
                else { completion(nil, String(r.out.suffix(300))) }
            }
        }
    }

    /// Neues Projekt anlegen: Ordner, git, README – auf Wunsch auch gleich als (privates) GitHub-Repo.
    func create(name: String, in base: String, onGitHub: Bool, isPrivate: Bool, completion: @escaping (_ path: String?, _ error: String?) -> Void) {
        let clean = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        let target = (base as NSString).appendingPathComponent(clean)
        guard !clean.isEmpty, !FileManager.default.fileExists(atPath: target) else { completion(nil, L("Ordner gibt es schon")); return }
        DispatchQueue.global(qos: .userInitiated).async {
            var cmd = "mkdir -p \(Shell.quote(target)) && cd \(Shell.quote(target)) && git init -q -b main && printf '# %s\\n' \(Shell.quote(clean)) > README.md && git add -A && git -c user.name=\"$(git config user.name || echo Salenta)\" -c user.email=\"$(git config user.email || echo salenta@localhost)\" commit -qm 'Start'"
            if onGitHub { cmd += " && gh repo create \(Shell.quote(clean)) \(isPrivate ? "--private" : "--public") --source . --push" }
            let r = Proc.zsh(cmd, in: base, timeout: 300)
            DispatchQueue.main.async {
                if FileManager.default.fileExists(atPath: target + "/.git") {
                    self.add(target, source: onGitHub && r.code == 0 ? "GitHub" : "Neu")
                    completion(target, r.code == 0 ? nil : L("Lokal angelegt, aber GitHub hat nicht geklappt: ") + String(r.out.suffix(200)))
                } else { completion(nil, String(r.out.suffix(300))) }
            }
        }
    }

    func loadGitHub(force: Bool = false) {
        guard force || github.isEmpty, !loadingGitHub else { return }
        loadingGitHub = true
        Shell.run("gh repo list --limit 300 --json nameWithOwner,url,updatedAt", timeout: 40) { [weak self] out, code in
            guard let self else { return }
            self.loadingGitHub = false
            guard code == 0, let s = out.firstIndex(of: "["), let e = out.lastIndex(of: "]"),
                  let d = String(out[s...e]).data(using: .utf8),
                  let list = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else {
                self.githubError = out.contains("not found") || out.contains("command not found")
                    ? L("GitHub CLI fehlt") : L("Noch nicht mit GitHub verbunden")
                return
            }
            self.githubError = nil
            self.github = list.compactMap { r in
                guard let n = r["nameWithOwner"] as? String else { return nil }
                return RemoteRepo(fullName: n, url: r["url"] as? String ?? "", updated: String((r["updatedAt"] as? String ?? "").prefix(10)))
            }.sorted { $0.updated > $1.updated }
        }
    }

    /// Ziel beim Klonen: ~/Code/<repo>
    func clonePath(_ repo: RemoteRepo) -> String {
        Paths.home.appendingPathComponent("Code").appendingPathComponent(repo.fullName.components(separatedBy: "/").last ?? repo.fullName).path
    }

    func localPath(for repo: RemoteRepo) -> String? {
        let name = repo.fullName.components(separatedBy: "/").last ?? ""
        return local.first { ($0.path as NSString).lastPathComponent == name && $0.isGit }?.path
    }

    static func scanLocal() -> [Project] {
        let fm = FileManager.default
        let home = Paths.home
        var out: [Project] = []
        var seen = Set<String>()

        func add(_ path: String, source: String) {
            var isDir: ObjCBool = false
            guard !seen.contains(path), fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return }
            seen.insert(path)
            let git = fm.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
            out.append(Project(path: path, name: (path as NSString).lastPathComponent, source: source, isGit: git))
        }

        // 1. Alle Projekte, in denen Claude Code schon gearbeitet hat
        if let d = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
           let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let projects = root["projects"] as? [String: Any] {
            for p in projects.keys.sorted() where p != home.path { add(p, source: "Claude Code") }
        }
        // 2. Git-Repos in den üblichen Ordnern (2 Ebenen tief)
        for base in ["Code", "Developer", "Projects", "Repos", "src", "GitHub", "go/src", "Claude"] {
            let dir = home.appendingPathComponent(base)
            guard fm.fileExists(atPath: dir.path) else { continue }
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) { add(dir.path, source: "Lokal") }
            for child in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !child.hasPrefix(".") {
                let p = dir.appendingPathComponent(child)
                if fm.fileExists(atPath: p.appendingPathComponent(".git").path) { add(p.path, source: "Lokal"); continue }
                for g in (try? fm.contentsOfDirectory(atPath: p.path)) ?? [] where !g.hasPrefix(".") {
                    let q = p.appendingPathComponent(g)
                    if fm.fileExists(atPath: q.appendingPathComponent(".git").path) { add(q.path, source: "Lokal") }
                }
            }
        }
        add(Paths.source.path, source: "Salenta Code")
        return out
    }
}

struct Skill: Identifiable, Hashable {
    var id: String { source + ":" + name }
    let name: String
    let description: String
    let source: String
    let path: String
}

final class SkillCatalog: ObservableObject {
    @Published var skills: [Skill] = []
    /// Für Stellen ohne Zugriff auf die Umgebung (z. B. automatische Skill-Wahl beim Agent-Start).
    static weak var current: SkillCatalog?

    init() { reload(); Self.current = self }

    func reload() {
        DispatchQueue.global(qos: .utility).async {
            let found = Self.scan()
            DispatchQueue.main.async { self.skills = found }
        }
    }

    /// Skills, die ein Agent kennt.
    func skills(for agent: AgentKind?) -> [Skill] {
        switch agent {
        case .claude?: skills.filter { ["Claude Code", "Plugin", "Agents"].contains($0.source) }
        case .codex?: skills.filter { ["Codex", "Agents"].contains($0.source) }
        case .junie?: skills.filter { ["Junie", "Agents"].contains($0.source) }
        default: skills
        }
    }

    private static func scan() -> [Skill] {
        let home = Paths.home
        var out: [Skill] = []
        var seen = Set<String>()
        let roots: [(String, String, Int)] = [
            (".claude/skills", "Claude Code", 2),
            (".claude/plugins", "Plugin", 7),
            (".agents/skills", "Agents", 2),
            (".codex/skills", "Codex", 3),
            (".junie/skills", "Junie", 3),
        ]
        for (rel, source, depth) in roots {
            let root = home.appendingPathComponent(rel)
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { continue }
            while let url = en.nextObject() as? URL {
                if en.level > depth { en.skipDescendants(); continue }
                guard url.lastPathComponent == "SKILL.md" else { continue }
                let (name, desc) = frontmatter(url)
                let n = name ?? url.deletingLastPathComponent().lastPathComponent
                let key = source + ":" + n
                if seen.insert(key).inserted {
                    out.append(Skill(name: n, description: desc ?? "", source: source, path: url.path))
                }
            }
        }
        return out.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private static func frontmatter(_ url: URL) -> (String?, String?) {
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.hasPrefix("---") else { return (nil, nil) }
        var name: String?, desc: String?
        for line in text.components(separatedBy: .newlines).dropFirst() {
            if line.hasPrefix("---") { break }
            if line.hasPrefix("name:") { name = line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            if line.hasPrefix("description:") { desc = line.dropFirst(12).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
        }
        return (name, desc)
    }
}

// MARK: - Auswahl-Popover

struct ProjectPicker: View {
    @EnvironmentObject private var projects: ProjectCatalog
    @EnvironmentObject private var agents: AgentManager
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.s) {
            Picker("", selection: $tab) {
                Text("Auf dem Mac (\(projects.local.count))").tag(0)
                Text("GitHub").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField("Repo oder Ordner suchen", text: $search).textFieldStyle(.roundedBorder)
            List {
                if tab == 0 {
                    ForEach(["Salenta Code", "Claude Code", "Lokal"], id: \.self) { src in
                        let list = projects.local.filter { $0.source == src && matches($0.name + $0.path) }
                        if !list.isEmpty {
                            Section(src == "Claude Code" ? "Mit Claude Code genutzt" : src == "Lokal" ? "Git-Repos" : src) {
                                ForEach(list) { p in
                                    Button { pick(p.path) } label: {
                                        HStack {
                                            Image(systemName: p.isGit ? "arrow.triangle.branch" : "folder")
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(p.name)
                                                Text(p.path.replacingOccurrences(of: Paths.home.path, with: "~")).font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            if p.path == selection { Image(systemName: "checkmark") }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                } else {
                    if projects.loadingGitHub { ProgressView() }
                    if let e = projects.githubError { Text(e).foregroundStyle(.secondary) }
                    ForEach(projects.github.filter { matches($0.fullName) }) { r in
                        HStack {
                            Image(systemName: "shippingbox")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.fullName)
                                Text("aktualisiert \(r.updated)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let path = projects.localPath(for: r) {
                                Button("Auswählen") { pick(path) }
                            } else {
                                Button("Klonen") {
                                    let target = projects.clonePath(r)
                                    agents.start(.shell, in: Paths.home.path, label: "Klone \(r.fullName)")
                                        .send("mkdir -p ~/Code && gh repo clone \(r.fullName) \(Shell.quote(target))\n")
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { projects.reload() }
                                    pick(target)
                                }
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 320)
            HStack {
                Button("Anderen Ordner …") { if let d = agents.chooseDirectory() { pick(d) } }
                Spacer()
                Button("Schließen") { dismiss() }
            }
        }
        .padding(Grid.m)
        .frame(width: 520, height: 480)
        .onChange(of: tab) { _, t in if t == 1 { projects.loadGitHub() } }
    }

    private func matches(_ s: String) -> Bool { search.isEmpty || s.localizedCaseInsensitiveContains(search) }

    private func pick(_ path: String) {
        selection = path
        agents.remember(path)
        dismiss()
    }
}

struct SkillPicker: View {
    @EnvironmentObject private var catalog: SkillCatalog
    let agent: AgentKind?
    @Binding var selected: Set<String>
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.s) {
            HStack {
                Text("Skills").font(.headline)
                Spacer()
                if !selected.isEmpty { Button("Keine") { selected = [] }.buttonStyle(.link) }
            }
            TextField("Skill suchen", text: $search).textFieldStyle(.roundedBorder)
            List {
                ForEach(catalog.skills(for: agent).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search) }) { s in
                    Toggle(isOn: Binding(get: { selected.contains(s.name) },
                                         set: { on in if on { selected.insert(s.name) } else { selected.remove(s.name) } })) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(s.name).font(.callout.weight(.medium))
                                Text(s.source).font(.caption2).foregroundStyle(.tertiary)
                            }
                            Text(s.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .frame(minHeight: 300)
        }
        .padding(Grid.m)
        .frame(width: 460, height: 440)
    }
}
