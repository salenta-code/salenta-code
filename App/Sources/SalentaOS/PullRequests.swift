import AgenticOSKit
import AppKit
import SwiftUI

// Ein Knopf für Commit, Push und Pull Request.
// Jeder Agent-Auftrag arbeitet auf seinem eigenen Branch (aos/…). Ist er gut, öffnet „Pull Request …“ ein Fenster mit
// fertig geschriebenem Titel, Beschreibung und Changelog (vom Modell aus Diff und Auftrag erzeugt, alles änderbar),
// den Änderungen zum Durchsehen, Entwurf ja/nein und der Basis – auch der Branch eines anderen Auftrags (gestapelte PRs).
// Danach bleibt der Auftrag offen: weitere Änderungen schiebst du mit einem Klick in denselben PR nach.
// Genutzt wird deine vorhandene GitHub-Anmeldung (gh). Nie Force-Push.

struct PRDraft: Equatable {
    var title = ""
    var body = ""
    var draft = false
    var base = ""
}

enum PRWriter {
    /// Commits, Dateien und Auszug aus dem Diff gegenüber der Basis.
    static func context(_ wt: WorktreeInfo, base: String) -> (commits: String, stat: String, diff: String) {
        let dir = Worktrees.top(wt)
        Git.run(["add", "-A", "--intent-to-add", "--"] + Worktrees.addSpec, in: dir)
        let mb = Git.run(["merge-base", "HEAD", base], in: dir).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let from = mb.isEmpty ? "HEAD" : mb
        let commits = Git.run(["log", "--pretty=- %s", "\(from)..HEAD"], in: dir).out
        let stat = Git.run(["diff", "--stat", from], in: dir).out
        let diff = String(Git.run(["diff", "--no-color", "-U2", from], in: dir).out.prefix(14_000))
        return (commits, stat, diff)
    }

    /// Titel und Beschreibung schreiben lassen (kleines, schnelles Modell; bei „Nur lokal“ das lokale). Fällt zurück auf eine einfache Fassung.
    static func generate(rec: MissionRecord, wt: WorktreeInfo, base: String) -> PRDraft {
        let c = context(wt, base: base)
        let de = Profile.languageCode == "de"
        let prompt = """
        Write a GitHub pull request for the change below. Answer ONLY with one JSON object, no prose:
        {"title": "...", "summary": ["..."], "changes": ["..."], "changelog": ["..."], "testing": ["..."]}
        Rules: title max 72 chars, imperative, conventional-commit prefix (feat:, fix:, refactor:, docs:, chore:, test:).
        summary: 1–3 bullets, why and what. changes: concrete changes per area/file group. changelog: 1–3 user-facing lines
        (empty if nothing user-facing). testing: how it was or can be verified. No secrets, no file contents.
        Language for all text except the title prefix: \(de ? "German" : "English").

        Task given to the agent:
        \(rec.request.prefix(1500))

        Commits:
        \(c.commits.prefix(2000))

        Files:
        \(c.stat.prefix(2500))

        Diff (excerpt):
        \(c.diff)
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("aos-pr-\(UUID().uuidString).md")
        try? prompt.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let r = Proc.zsh(HelperLLM.command(model: "haiku", maxTurns: 3, file: file.path),
                         in: NSTemporaryDirectory(), timeout: 120)
        var d = PRDraft(base: base)
        if let res = Verifier.claudeResult(r.out), let a = res.firstIndex(of: "{"), let b = res.lastIndex(of: "}"),
           let j = try? JSONSerialization.jsonObject(with: Data(res[a...b].utf8)) as? [String: Any] {
            func list(_ k: String) -> [String] { (j[k] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            d.title = (j["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            d.body = body(summary: list("summary"), changes: list("changes"), changelog: list("changelog"), testing: list("testing"), rec: rec, de: de)
        }
        if d.title.isEmpty {   // ohne Modell: einfache, ehrliche Fassung
            d.title = String(rec.title.prefix(72))
            let files = c.stat.split(separator: "\n").dropLast().map { "`" + ($0.split(separator: "|").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "") + "`" }
            d.body = body(summary: [rec.request.components(separatedBy: .newlines).first ?? rec.title],
                          changes: c.commits.split(separator: "\n").map { String($0.dropFirst(2)) } + (files.isEmpty ? [] : [files.prefix(15).joined(separator: ", ")]),
                          changelog: [], testing: [], rec: rec, de: de)
        }
        return d
    }

    static func body(summary: [String], changes: [String], changelog: [String], testing: [String], rec: MissionRecord, de: Bool) -> String {
        func section(_ t: String, _ items: [String]) -> String { items.isEmpty ? "" : "## \(t)\n" + items.map { "- " + $0 }.joined(separator: "\n") + "\n\n" }
        var b = section(de ? "Zusammenfassung" : "Summary", summary)
        b += section(de ? "Änderungen" : "Changes", changes)
        b += section("Changelog", changelog)
        var checks = testing
        if let v = rec.verify, v.finished != nil {
            checks += v.checks.map { "\($0.ok == true ? "✅" : "❌") \($0.name): `\($0.command)`" }
            if let r = v.review { checks.append("\(r.ok ? "✅" : "❌") Review (\(r.agent)): \(r.summary)") }
        }
        b += section(de ? "Geprüft" : "Testing", checks)
        return b + "---\n" + (de ? "Erstellt mit Salenta Code" : "Created with Salenta Code")
    }
}

extension Worktrees {
    /// Commit, Push und PR in einem Schritt. Gibt die PR-Adresse zurück. Die Arbeitskopie bleibt für Nachträge erhalten.
    static func openPR(_ wt: WorktreeInfo, draft d: PRDraft) -> (Bool, String) {
        guard let gh = Detection.which("gh") else { return (false, L("GitHub CLI fehlt – Einstellungen › Einrichtung › „gh“ installieren")) }
        let dir = top(wt)
        guard Proc.zsh("gh auth status", in: dir, timeout: 20).code == 0 else {
            return (false, L("Bei GitHub nicht angemeldet – einmal im Terminal: gh auth login"))
        }
        Git.run(["add", "-A", "--"] + addSpec, in: dir)
        if Git.run(["diff", "--cached", "--quiet"], in: dir).code != 0 {
            Git.run(Git.identity(dir) + ["commit", "-m", d.title], in: dir)
        }
        // Gestapelt: die Basis ist der Branch eines anderen Auftrags – der muss auf GitHub liegen
        if d.base != wt.baseBranch {
            let b = Git.run(["push", "-u", "origin", d.base], in: wt.base, timeout: 120)
            guard b.code == 0 else { return (false, L("Basis-Branch konnte nicht hochgeladen werden: ") + String(b.out.suffix(200))) }
        }
        let push = Git.run(["push", "-u", "origin", wt.branch], in: dir, timeout: 180)
        guard push.code == 0 else { return (false, String(push.out.suffix(300))) }
        let bodyFile = FileManager.default.temporaryDirectory.appendingPathComponent("aos-prbody-\(UUID().uuidString).md")
        try? d.body.write(to: bodyFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bodyFile) }
        let r = Proc.zsh("\(Shell.quote(gh)) pr create --head \(Shell.quote(wt.branch)) --base \(Shell.quote(d.base)) --title \(Shell.quote(d.title)) --body-file \(Shell.quote(bodyFile.path))\(d.draft ? " --draft" : "")",
                         in: dir, timeout: 120)
        let url = r.out.split(separator: "\n").map(String.init).last { $0.hasPrefix("https://") } ?? ""
        return (r.code == 0 && !url.isEmpty, url.isEmpty ? String(r.out.suffix(300)) : url)
    }

    /// Neue Änderungen in denselben PR nachschieben (normaler Push), auf Wunsch mit neuer Beschreibung.
    static func amendPR(_ wt: WorktreeInfo, message: String, newBody: String?) -> (Bool, String) {
        let dir = top(wt)
        Git.run(["add", "-A", "--"] + addSpec, in: dir)
        let staged = Git.run(["diff", "--cached", "--quiet"], in: dir).code != 0
        if staged { Git.run(Git.identity(dir) + ["commit", "-m", message], in: dir) }
        let push = Git.run(["push", "origin", wt.branch], in: dir, timeout: 180)
        guard push.code == 0 else { return (false, String(push.out.suffix(300))) }
        if let newBody, let gh = Detection.which("gh") {
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("aos-prbody-\(UUID().uuidString).md")
            try? newBody.write(to: f, atomically: true, encoding: .utf8)
            _ = Proc.zsh("\(Shell.quote(gh)) pr edit \(Shell.quote(wt.branch)) --body-file \(Shell.quote(f.path))", in: dir, timeout: 60)
            try? FileManager.default.removeItem(at: f)
        }
        return (true, staged ? L("Nachgeschoben – der Pull Request ist aktuell") : L("Nichts Neues – der Pull Request war schon aktuell"))
    }

    /// Andere offene Agent-Branches desselben Repos (für gestapelte PRs).
    static func stackCandidates(for rec: MissionRecord, wt: WorktreeInfo) -> [(branch: String, title: String)] {
        MissionStore.shared.missions.compactMap { m in
            guard m.id != rec.id, m.archived != true || m.pr != nil, let w = m.worktree, w.base == wt.base, w.branch != wt.branch else { return nil }
            return (w.branch, m.title)
        }
    }
}

/// Fenster „Pull Request“: alles vorbereitet, du prüfst und klickst einmal.
struct PRSheet: View {
    let rec: MissionRecord
    let wt: WorktreeInfo
    let files: [Worktrees.FileChange]
    let done: (Bool, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var d = PRDraft()
    @State private var writing = true
    @State private var sending = false
    @State private var open: String?
    @State private var diffText = ""
    @AppStorage("pr.draftDefault") private var draftDefault = false

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.m) {
            HStack {
                Label(L("Pull Request auf GitHub"), systemImage: "arrow.triangle.pull").font(.title3.weight(.semibold))
                Spacer()
                if writing { ProgressView().controlSize(.small); Text("Schreibe Titel und Beschreibung …").font(.caption).foregroundStyle(.secondary) }
                Button { regenerate() } label: { Label(L("Neu schreiben"), systemImage: "sparkles") }
                    .disabled(writing).help(L("Titel, Beschreibung und Changelog neu aus den Änderungen erzeugen"))
            }
            TextField(L("Titel"), text: $d.title).textFieldStyle(.roundedBorder).font(.body.weight(.medium))
            TextEditor(text: $d.body)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 180, maxHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                .dictation($d.body)
            HStack(spacing: Grid.l) {
                Picker(L("Basis"), selection: $d.base) {
                    Text(wt.baseBranch).tag(wt.baseBranch)
                    let stack = Worktrees.stackCandidates(for: rec, wt: wt)
                    if !stack.isEmpty {
                        Divider()
                        ForEach(stack, id: \.branch) { s in Text(L("Auf „") + String(s.title.prefix(40)) + "“ (\(s.branch))").tag(s.branch) }
                    }
                }
                .fixedSize()
                .help(L("Worauf der PR aufbaut – wähle einen anderen Auftrag, um PRs zu stapeln"))
                Toggle(L("Als Entwurf"), isOn: $d.draft).help(L("Entwurf: noch nicht bereit zum Mergen – Prüfungen laufen trotzdem"))
                Spacer()
            }
            // Änderungen direkt hier durchsehen, bevor sie hochgehen
            DisclosureGroup {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(files.prefix(80)) { f in
                            Button {
                                open = open == f.path ? nil : f.path
                                if let o = open { DispatchQueue.global().async { let t = Worktrees.diff(wt, file: o); DispatchQueue.main.async { diffText = t } } }
                            } label: {
                                HStack {
                                    Image(systemName: open == f.path ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 10)
                                    Text(f.path).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text("+\(f.added)").foregroundStyle(.green).font(.caption.monospacedDigit())
                                    Text("−\(f.removed)").foregroundStyle(.red).font(.caption.monospacedDigit())
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if open == f.path { DiffText(text: diffText).padding(.vertical, 4) }
                        }
                    }
                }
                .frame(maxHeight: 220)
            } label: {
                Text("\(files.count) \(files.count == 1 ? L("Datei") : L("Dateien"))  ") + Text("+\(files.map(\.added).reduce(0, +)) −\(files.map(\.removed).reduce(0, +))").foregroundColor(.secondary)
            }
            .font(.callout)
            Text(String(format: L("Wird committet und als Branch „%@“ hochgeladen. Nie Force-Push. Deine GitHub-Anmeldung (gh) wird genutzt."), wt.branch))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L("Abbrechen")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    sending = true
                    draftDefault = d.draft
                    let draft = d
                    DispatchQueue.global(qos: .userInitiated).async {
                        let r = Worktrees.openPR(wt, draft: draft)
                        DispatchQueue.main.async { sending = false; if r.0 { dismiss() }; done(r.0, r.1) }
                    }
                } label: {
                    if sending { ProgressView().controlSize(.small) } else { Label(L("Committen, pushen & PR öffnen"), systemImage: "arrow.up.forward.app") }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(writing || sending || d.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Grid.xl)
        .frame(width: 680)
        .onAppear { d.base = wt.baseBranch; d.draft = draftDefault; regenerate() }
    }

    private func regenerate() {
        writing = true
        let base = d.base.isEmpty ? wt.baseBranch : d.base, draft = d.draft
        DispatchQueue.global(qos: .userInitiated).async {
            var g = PRWriter.generate(rec: rec, wt: wt, base: base)
            g.draft = draft
            DispatchQueue.main.async { d = g; writing = false }
        }
    }
}
