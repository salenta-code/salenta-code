import AgenticOSKit
import AppKit
import SwiftUI

// „Alle PRs prüfen“: Für jeden offenen Pull Request harte Fakten sammeln (ist der Inhalt schon im Haupt-Branch?
// Konflikte? Was kam seitdem dazu? CI?), dann bewertet Claude Opus alle zusammen und empfiehlt pro PR:
// mergen, nachbessern lassen, schließen (veraltet/überholt) oder liegen lassen. Du siehst alles und führst mit einem Klick aus.

struct PRVerdict: Identifiable, Hashable {
    enum Action: String, CaseIterable { case merge, fix, close, wait
        var title: String {
            switch self { case .merge: L("Mergen"); case .fix: L("Nachbessern lassen"); case .close: L("Schließen (veraltet)"); case .wait: L("Liegen lassen") }
        }
        var symbol: String {
            switch self { case .merge: "arrow.triangle.merge"; case .fix: "wrench.and.screwdriver"; case .close: "xmark.bin"; case .wait: "pause.circle" }
        }
        var tint: Color { switch self { case .merge: .green; case .fix: .orange; case .close: .secondary; case .wait: .blue } }
    }
    var id: Int { number }
    let number: Int
    let title: String
    let url: String
    let branch: String
    let author: String
    let crossRepo: Bool
    var facts: String
    var action: Action = .wait
    var reason = ""
    var result: String?
    var ok: Bool?
}

final class PRTriage: ObservableObject {
    static let shared = PRTriage()
    enum Phase: Equatable { case idle, collecting(Int, Int), judging, ready, executing(Int, Int), done, failed(String) }
    @Published private(set) var phase: [String: Phase] = [:]
    @Published var items: [String: [PRVerdict]] = [:]
    /// Welches Repo gerade im Fenster „Alle PRs prüfen“ offen ist
    @Published var sheet: SheetRepo?
    struct SheetRepo: Identifiable { var id: String { path }; let path: String }
    func open(_ repo: String) { sheet = SheetRepo(path: repo) }

    func set(_ repo: String, _ p: Phase) { DispatchQueue.main.async { self.phase[repo] = p } }

    // MARK: Prüfen

    func analyze(_ repo: String) {
        if case .collecting = phase[repo] { return }
        if phase[repo] == .judging { return }
        set(repo, .collecting(0, 0))
        DispatchQueue.global(qos: .userInitiated).async {
            let def = Self.defaultBranch(repo)
            _ = Git.run(["fetch", "--quiet", "origin", def], in: repo, timeout: 120)
            let r = Proc.zsh("gh pr list --state open --limit 50 --json number,title,url,headRefName,isDraft,mergeable,author,isCrossRepository,statusCheckRollup,createdAt,files",
                             in: repo, timeout: 90)
            guard r.code == 0, let a = r.out.firstIndex(of: "["),
                  let arr = try? JSONSerialization.jsonObject(with: Data(r.out[a...].utf8)) as? [[String: Any]] else {
                self.set(repo, .failed(GitError.explain(r.out)))
                return
            }
            var out: [PRVerdict] = []
            for (k, j) in arr.enumerated() {
                self.set(repo, .collecting(k + 1, arr.count))
                guard let n = j["number"] as? Int else { continue }
                out.append(Self.facts(repo: repo, def: def, j: j, number: n))
            }
            guard !out.isEmpty else { DispatchQueue.main.async { self.items[repo] = []; self.phase[repo] = .ready }; return }
            self.set(repo, .judging)
            let judged = Self.judge(repo: repo, items: out)
            DispatchQueue.main.async { self.items[repo] = judged; self.phase[repo] = .ready }
        }
    }

    static func defaultBranch(_ repo: String) -> String {
        let h = Git.run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repo, timeout: 10).out.trimmingCharacters(in: .whitespacesAndNewlines)
        return h.hasPrefix("origin/") ? String(h.dropFirst(7)) : "main"
    }

    /// Harte Fakten pro PR – ohne KI, direkt aus git.
    private static func facts(repo: String, def: String, j: [String: Any], number n: Int) -> PRVerdict {
        let ref = "refs/salenta/pr/\(n)"
        _ = Git.run(["fetch", "--quiet", "origin", "pull/\(n)/head:\(ref)", "--force"], in: repo, timeout: 90)
        let main = "origin/" + def
        let base = Git.run(["merge-base", ref, main], in: repo, timeout: 15).out.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        let checks = (j["statusCheckRollup"] as? [[String: Any]]) ?? []
        let st = checks.map { (($0["conclusion"] as? String) ?? ($0["status"] as? String) ?? "").uppercased() }
        let ci = checks.isEmpty ? "none" : st.contains { ["FAILURE", "ERROR", "TIMED_OUT", "ACTION_REQUIRED"].contains($0) } ? "red"
            : st.allSatisfy { ["SUCCESS", "NEUTRAL", "SKIPPED", "CANCELLED", "STALE"].contains($0) } ? "green" : "pending"
        lines.append("CI: \(ci) · mergeable: \(j["mergeable"] as? String ?? "?") · draft: \(j["isDraft"] as? Bool ?? false) · created: \(j["createdAt"] as? String ?? "?")")
        if !base.isEmpty {
            // Bringt der PR überhaupt noch etwas? Ergebnis des Merges == Haupt-Branch → nichts Neues mehr
            let merged = Git.run(["merge-tree", "--write-tree", main, ref], in: repo, timeout: 60)
            let mainTree = Git.run(["rev-parse", main + "^{tree}"], in: repo, timeout: 10).out.trimmingCharacters(in: .whitespacesAndNewlines)
            let first = merged.out.split(separator: "\n").first.map(String.init) ?? ""
            if merged.code == 0, first == mainTree { lines.append("FACT: merging this PR changes NOTHING – its content is already in \(def).") }
            if merged.code == 1 { lines.append("FACT: merging now would CONFLICT.") }
            let cherry = Git.run(["cherry", main, ref], in: repo, timeout: 30).out.split(separator: "\n")
            let upstream = cherry.filter { $0.hasPrefix("-") }.count
            if !cherry.isEmpty { lines.append("Commits: \(cherry.count), already applied upstream: \(upstream)") }
            let since = Git.run(["log", "--oneline", "--no-merges", "-25", base + ".." + main], in: repo, timeout: 15).out
            let behind = Git.run(["rev-list", "--count", base + ".." + main], in: repo, timeout: 15).out.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("\(def) moved on by \(behind) commits since this PR branched. Recent ones:\n" + since.split(separator: "\n").prefix(12).joined(separator: "\n"))
            let prFiles = Set(((j["files"] as? [[String: Any]]) ?? []).compactMap { $0["path"] as? String })
            let mainFiles = Set(Git.run(["diff", "--name-only", base, main], in: repo, timeout: 30).out.split(separator: "\n").map(String.init))
            let overlap = prFiles.intersection(mainFiles)
            if !overlap.isEmpty { lines.append("Files ALSO changed on \(def) since then: " + overlap.prefix(15).joined(separator: ", ")) }
        }
        let diff = Git.run(["diff", "--stat", base.isEmpty ? main : base, ref], in: repo, timeout: 30).out
        let patch = Git.run(["diff", base.isEmpty ? main : base, ref], in: repo, timeout: 30).out
        lines.append("Diffstat:\n" + String(diff.suffix(1500)))
        lines.append("Patch (truncated):\n" + String(patch.prefix(6000)))
        return PRVerdict(number: n, title: j["title"] as? String ?? "", url: j["url"] as? String ?? "",
                         branch: j["headRefName"] as? String ?? "", author: (j["author"] as? [String: Any])?["login"] as? String ?? "",
                         crossRepo: j["isCrossRepository"] as? Bool ?? false, facts: lines.joined(separator: "\n"))
    }

    /// Opus bewertet alle PRs zusammen (sieht auch Überschneidungen und Dubletten zwischen PRs).
    private static func judge(repo: String, items: [PRVerdict]) -> [PRVerdict] {
        var budget = 150_000
        let blocks = items.map { v -> String in
            let b = "=== PR #\(v.number): \(v.title) (by \(v.author), branch \(v.branch))\n" + v.facts
            let cut = String(b.prefix(max(2000, min(b.count, budget / max(items.count, 1)))))
            budget -= cut.count
            return cut
        }
        let lang = Profile.languageCode == "de" ? "German (plain, one sentence)" : "English (one sentence)"
        let prompt = """
        You triage ALL open pull requests of the repository \((repo as NSString).lastPathComponent) for its busy, non-developer owner.
        For each PR decide exactly one action:
        - "merge": still needed, correct, safe, CI green or none, no conflict.
        - "fix": still needed but has problems (red CI, conflict with newer changes, bugs, outdated against newer code) → an agent will repair it.
        - "close": obsolete – content already in the main branch (see FACT lines), superseded by a newer PR or by later commits, or no longer makes sense.
        - "wait": draft, risky without the owner's decision, or unclear.
        Use the FACT lines as ground truth. Consider overlaps and duplicates between PRs (keep the best, close the others).
        Answer ONLY with JSON: {"items":[{"number":1,"action":"merge|fix|close|wait","reason":"\(lang)"}]}

        \(blocks.joined(separator: "\n\n"))
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("aos-triage-\(UUID().uuidString).md")
        try? prompt.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        var verdicts: [Int: (String, String)] = [:]
        for model in ["opus", "sonnet"] {
            let r = Proc.zsh("claude -p --model \(model) --output-format json --max-turns 3 --strict-mcp-config < \(Shell.quote(file.path))",
                             in: NSTemporaryDirectory(), timeout: 600)
            if let res = Verifier.claudeResult(r.out), let a = res.firstIndex(of: "{"), let b = res.lastIndex(of: "}"), a < b,
               let j = try? JSONSerialization.jsonObject(with: Data(res[a...b].utf8)) as? [String: Any],
               let list = j["items"] as? [[String: Any]] {
                for i in list { if let n = i["number"] as? Int { verdicts[n] = (i["action"] as? String ?? "wait", i["reason"] as? String ?? "") } }
                break
            }
        }
        return items.map { v in
            var x = v
            if let (a, why) = verdicts[v.number] { x.action = PRVerdict.Action(rawValue: a) ?? .wait; x.reason = why }
            else {
                // ohne KI: nur die harten Fakten
                if v.facts.contains("changes NOTHING") { x.action = .close; x.reason = L("Inhalt ist schon im Haupt-Branch") }
                else if v.facts.contains("CONFLICT") || v.facts.contains("CI: red") { x.action = .fix; x.reason = L("Konflikt oder rote CI") }
                else { x.action = .wait; x.reason = L("Keine KI-Bewertung möglich – bitte selbst ansehen") }
            }
            return x
        }
    }

    // MARK: Ausführen

    func setAction(_ repo: String, _ n: Int, _ a: PRVerdict.Action) {
        guard let i = items[repo]?.firstIndex(where: { $0.number == n }) else { return }
        items[repo]![i].action = a
    }

    func execute(_ repo: String) {
        guard let list = items[repo] else { return }
        let todo = list.filter { $0.action != .wait && $0.ok == nil }
        guard !todo.isEmpty else { return }
        // Nachbessern über den Projekt-Betreuer (er übernimmt Korrektur, Prüfung und Merge)
        let fixes = todo.filter { $0.action == .fix }
        var stewardID: String?
        if !fixes.isEmpty { stewardID = Steward.shared.adopt(repo) }
        set(repo, .executing(0, todo.count))
        DispatchQueue.global(qos: .userInitiated).async {
            for (k, v) in todo.enumerated() {
                self.set(repo, .executing(k + 1, todo.count))
                var ok = false, msg = ""
                switch v.action {
                case .merge:
                    // Stand kann sich durch vorige Merges geändert haben – erst frisch prüfen
                    let st = Proc.zsh("gh pr view \(v.number) --json mergeable,statusCheckRollup", in: repo, timeout: 60).out
                    if st.contains("\"CONFLICTING\"") { msg = L("inzwischen Konflikt – nicht gemergt"); break }
                    if st.contains("\"FAILURE\"") { msg = L("CI rot – nicht gemergt"); break }
                    (ok, msg) = GitSync.mergePR(repo: repo, number: v.number)
                    if !ok { msg = GitError.explain(msg) }
                case .close:
                    let note = "🧭 " + L("Geschlossen vom Projekt-Betreuer (Salenta Code):") + " " + v.reason
                    let f = FileManager.default.temporaryDirectory.appendingPathComponent("aos-close-\(v.number).md")
                    try? note.write(to: f, atomically: true, encoding: .utf8)
                    let r = Proc.zsh("gh pr close \(v.number) --comment \"$(cat \(Shell.quote(f.path)))\"" + (v.crossRepo ? "" : " --delete-branch"), in: repo, timeout: 60)
                    try? FileManager.default.removeItem(at: f)
                    ok = r.code == 0; msg = ok ? L("geschlossen") : GitError.explain(r.out)
                case .fix:
                    if v.crossRepo {
                        let r = Proc.zsh("gh pr comment \(v.number) --body \(Shell.quote("🧭 " + L("Bitte nachbessern:") + " " + v.reason))", in: repo, timeout: 60)
                        ok = r.code == 0; msg = L("Fremder Fork – Hinweis als Kommentar hinterlassen")
                    } else if let sid = stewardID {
                        DispatchQueue.main.sync {
                            Steward.shared.update(sid) { p in
                                p.tasks.append(StewardTask(title: String(format: L("PR #%d nachbessern: "), v.number) + v.title,
                                                           detail: v.reason + "\n\n" + L("Bring den PR auf den neuesten Stand des Haupt-Branches, löse Konflikte, behebe Fehler und rote Prüfungen."),
                                                           state: .queued, source: "ci", priority: 1, ref: v.url, pr: v.number, prBranch: v.branch))
                            }
                            Steward.shared.dispatch(sid)
                        }
                        ok = true; msg = L("Korrektur beim Projekt-Betreuer eingereiht")
                    }
                case .wait: continue
                }
                DispatchQueue.main.async {
                    if let i = self.items[repo]?.firstIndex(where: { $0.number == v.number }) { self.items[repo]![i].ok = ok; self.items[repo]![i].result = msg }
                }
            }
            if let sid = stewardID { DispatchQueue.main.async { Steward.shared.scanPRs(sid, force: true) } }
            self.set(repo, .done)
            let merged = todo.filter { $0.action == .merge }.count
            DispatchQueue.main.async {
                Celebration.shared.fire(L("Pull Requests aufgeräumt"), (repo as NSString).lastPathComponent, symbol: "arrow.triangle.merge", tint: .purple)
                if merged > 0 { _ = GitSync.update(repo: repo) }
            }
        }
    }
}

/// Fenster „Alle PRs prüfen“.
struct PRTriageSheet: View {
    let repo: String
    @ObservedObject private var t = PRTriage.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let list = t.items[repo] ?? []
        let phase = t.phase[repo] ?? .idle
        VStack(alignment: .leading, spacing: Grid.m) {
            HStack {
                Image(systemName: "arrow.triangle.pull").font(.title2).foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Alle Pull Requests prüfen").font(.title3.weight(.semibold))
                    Text((repo as NSString).lastPathComponent).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Schließen")) { dismiss() }
            }
            Text("Für jeden PR wird geprüft: Ist der Inhalt schon im Haupt-Branch? Gibt es Konflikte mit neueren Änderungen? Was kam seitdem dazu? Wie steht die CI? Danach bewertet Claude Opus alle zusammen – auch Dubletten.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            status(phase)
            if !list.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) { ForEach(list) { row($0) } }
                }
                let counts = Dictionary(grouping: list.filter { $0.ok == nil }, by: \.action).mapValues(\.count)
                HStack {
                    Text(PRVerdict.Action.allCases.compactMap { a in counts[a].map { "\($0)× " + a.title } }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Neu prüfen")) { t.analyze(repo) }.disabled(busy(phase))
                    Button { t.execute(repo) } label: { Label(L("Ausführen"), systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).tint(.purple)
                        .disabled(busy(phase) || list.allSatisfy { $0.action == .wait || $0.ok != nil })
                        .help(L("Mergt, schließt und lässt nachbessern – genau wie oben ausgewählt. Vor jedem Merge wird der Stand frisch geprüft."))
                }
            }
        }
        .padding(Grid.l)
        .frame(width: 760, height: 620)
        .onAppear { if t.items[repo] == nil, !busy(phase) { t.analyze(repo) } }
    }

    private func busy(_ p: PRTriage.Phase) -> Bool {
        switch p { case .collecting, .judging, .executing: return true; default: return false }
    }

    @ViewBuilder private func status(_ p: PRTriage.Phase) -> some View {
        switch p {
        case .collecting(let i, let n): HStack { ProgressView().controlSize(.small); Text(n == 0 ? L("Lese Pull Requests …") : String(format: L("Sammle Fakten: PR %d von %d …"), i, n)) }
        case .judging: HStack { ProgressView().controlSize(.small); Text("Claude Opus bewertet alle Pull Requests …") }
        case .executing(let i, let n): HStack { ProgressView().controlSize(.small); Text(String(format: L("Führe aus: %d von %d …"), i, n)) }
        case .done: Label(L("Fertig. Nachbesserungen laufen beim Projekt-Betreuer weiter und werden nach grüner Prüfung gemergt."), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let e): Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .ready: if (t.items[repo] ?? []).isEmpty { Text("Keine offenen Pull Requests.").foregroundStyle(.secondary) }
        case .idle: EmptyView()
        }
    }

    private func row(_ v: PRVerdict) -> some View {
        HStack(alignment: .top, spacing: Grid.s) {
            Image(systemName: v.ok == true ? "checkmark.circle.fill" : v.ok == false ? "xmark.circle.fill" : v.action.symbol)
                .foregroundStyle(v.ok == true ? .green : v.ok == false ? .red : v.action.tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("#\(v.number) \(v.title)").fontWeight(.medium).lineLimit(1)
                    Text("@" + v.author).font(.caption2).foregroundStyle(.tertiary)
                }
                Text(v.result ?? v.reason).font(.caption).foregroundStyle(v.ok == false ? .red : .secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if v.ok == nil {
                Picker("", selection: Binding(get: { v.action }, set: { t.setAction(repo, v.number, $0) })) {
                    ForEach(PRVerdict.Action.allCases, id: \.self) { a in Label(a.title, systemImage: a.symbol).tag(a) }
                }
                .labelsHidden().frame(width: 190)
            }
            if let u = URL(string: v.url) { Link(destination: u) { Image(systemName: "arrow.up.right.square") }.help(L("Auf GitHub öffnen")) }
        }
        .padding(Grid.s)
        .background(ModernCardBackground(radius: 10, accent: false))
    }
}
