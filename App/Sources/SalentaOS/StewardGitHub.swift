import AgenticOSKit
import SwiftUI

// Projekt-Betreuer + GitHub (über die GitHub CLI `gh`):
//  • liefert grüne Ergebnisse als Pull Request statt lokal zu mergen
//  • beobachtet alle offenen PRs des Repos: CI-Stand, Konflikte, Review-Stand
//  • prüft jeden neuen PR-Stand selbst (Review durch Claude Opus) und schreibt das Review als Kommentar
//  • merged grüne, geprüfte PRs selbst (eigene immer, fremde nur wenn erlaubt) und holt danach den neuen Stand
//  • rote CI im eigenen PR → Korrekturaufgabe direkt auf dem PR-Branch

struct StewardPR: Codable, Identifiable, Hashable {
    var id: Int { number }
    var number: Int
    var title: String
    var url: String
    var branch: String
    var sha: String
    var author: String = ""
    var draft = false
    var ours = false                   // von Salenta Code angelegt (Branch aos/…)
    var ci = "none"                    // green, red, pending, none
    var mergeable = "UNKNOWN"          // MERGEABLE, CONFLICTING, UNKNOWN
    var reviewedSha: String?
    var reviewOK: Bool?
    var risk: String?
    var summary: String?
    var issues: [String]? = nil
    var reviewing: Bool? = nil
    var fixedSha: String?              // für diesen Stand schon eine Korrektur geplant
    var fixCount: Int? = nil           // automatische Korrekturrunden (höchstens 2, dann entscheidest du)
    var rerunSha: String? = nil        // für diesen Stand schon einmal die CI neu gestartet (Infrastruktur-Fehler)
    var cleanedSha: String? = nil      // für diesen Stand schon nach Debug-Dateien gesucht
    var base: String? = nil            // Ziel-Branch des PRs
    var lookSha: String? = nil         // für diesen Stand schon gemeldet: Optik-Änderung wartet auf dein Ok
    var identitySha: String? = nil     // für diesen Stand schon geprüft: letzter Commit deinem GitHub-Konto zugeordnet?

    /// Verändert der PR das Aussehen? Geschmack entscheidet der Besitzer – solche PRs werden nie selbst gemergt.
    var changesLook: Bool {
        let t = title.lowercased()
        return ["design", "startseite", "homepage", "landing", "layout", "optik", "hero", "redesign", "look", "gestaltung", "gestalten", "theme", "farben", "typografie"]
            .contains { t.contains($0) }
    }
}

enum GH {
    private static var authCache: (ok: Bool, at: Date)?
    private static var checking = false
    private static let lock = NSLock()
    /// gh installiert und angemeldet? Nie blockierend: gemerkter Wert, im Hintergrund alle 10 min aufgefrischt.
    /// Geprüft wird der lokal gespeicherte Token (`gh auth token`) – `gh auth status` fragt GitHub ab und meldet offline fälschlich „nicht angemeldet“.
    static var ready: Bool { state == .ok }
    enum State { case unknown, ok, no }
    static var state: State {
        lock.lock(); let c = authCache; let busy = checking; lock.unlock()
        if c == nil || Date().timeIntervalSince(c!.at) > 600, !busy {
            lock.lock(); checking = true; lock.unlock()
            DispatchQueue.global(qos: .utility).async {
                let ok = Detection.which("gh") != nil && Proc.zsh("gh auth token >/dev/null 2>&1", in: NSTemporaryDirectory(), timeout: 15).code == 0
                lock.lock(); authCache = (ok, Date()); checking = false; lock.unlock()
            }
        }
        guard let c else { return .unknown }
        return c.ok ? .ok : .no
    }
    /// Beim Start einmal prüfen, damit das erste grüne Ergebnis nicht an GitHub vorbei übernommen wird.
    static func prime() { _ = state }
}

extension StewardProject {
    var hasGitHub: Bool { setup?.remote?.contains("github") == true }
    /// „owner/repo“ – gleich für alle Klone desselben GitHub-Repos
    var repoSlug: String? {
        guard let r = setup?.remote, r.contains("github") else { return nil }
        var s = r.lowercased().replacingOccurrences(of: ".git", with: "")
        for p in ["https://github.com/", "http://github.com/", "git@github.com:", "ssh://git@github.com/"] { s = s.replacingOccurrences(of: p, with: "") }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    /// Ergebnisse als Pull Request liefern?
    /// GitHub-Projekt mit eingeschaltetem Wächter: Ergebnisse gehen als Pull Request – solange gh nicht sicher fehlt.
    var viaPR: Bool { hasGitHub && (github ?? true) && GH.state != .no }
    var mergesPRs: Bool { autoMerge ?? (trust >= 2) }
}

extension Steward {

    // MARK: Ergebnis als PR liefern

    func deliverPR(_ id: String, task t: StewardTask, mid: String, wt: WorktreeInfo) {
        // Alte Arbeitskopie, die auf einem anderen Branch als dem Ziel aufsetzt (z. B. lokaler Feature-Branch mit
        // nicht hochgeladenen Commits)? Nicht liefern – sonst landen fremde Commits im PR. Aufgabe frisch vom Ziel-Branch neu starten.
        if t.prBranch == nil, let p = project(id) {
            let target = p.prBase ?? p.setup?.defaultBranch ?? "main"
            if wt.baseBranch != target {
                Worktrees.discard(wt, keepBranch: true)
                finishMission(mid, outcome: "discarded")
                update(id) { q in
                    if let i = q.tasks.firstIndex(where: { $0.id == t.id }) {
                        q.tasks[i].state = .queued; q.tasks[i].missionID = nil
                        q.tasks[i].note = String(format: L("Neu gestartet auf „%@“ – die alte Arbeitskopie baute auf „%@“ auf."), target, wt.baseBranch)
                    }
                }
                say(id, "status", "↻ " + String(format: L("Neu auf „%@“ aufgesetzt: "), target) + t.title)
                dispatch(id)
                return
            }
        }
        // Offline: Ergebnis lokal sichern (Commit in der Arbeitskopie) und später hochladen – nicht als Fehler behandeln
        if !LocalFirst.shared.isOnline {
            Worktrees.commitAll(wt, message: t.title)
            update(id) { p in
                if let i = p.tasks.firstIndex(where: { $0.id == t.id }) {
                    p.tasks[i].state = .review; p.tasks[i].offlineWT = wt; p.tasks[i].offlineMid = mid
                    p.tasks[i].note = "📡 " + L("Offline fertig und lokal gesichert – wird hochgeladen, sobald Internet da ist")
                }
            }
            say(id, "status", "📡 " + L("Offline fertig, lokal gesichert: ") + t.title)
            return
        }
        update(id) { p in
            if let i = p.tasks.firstIndex(where: { $0.id == t.id }) { p.tasks[i].state = .review; p.tasks[i].note = L("wird als Pull Request hochgeladen …") }
        }
        let body = (MissionStore.shared.mission(mid)?.digest?.summary ?? t.detail) + "\n\n— " + L("erstellt vom Projekt-Betreuer in Salenta Code, Prüfschleife grün")
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = false, msg = "", number: Int?
            if let branch = t.prBranch {
                // Korrektur auf bestehendem PR-Branch
                // Korrektur obendrauf hochladen: erst den aktuellen PR-Stand holen und ggf. einarbeiten (kein Überschreiben fremder Änderungen)
                Worktrees.commitAll(wt, message: t.title)
                let dir = Worktrees.top(wt)
                Git.run(["fetch", "--quiet", "origin", "+refs/heads/\(branch):refs/remotes/origin/\(branch)"], in: dir, timeout: 90)
                var r = Git.run(["push", "origin", "HEAD:refs/heads/" + branch], in: dir, timeout: 120)
                if r.code != 0, GitError.explain(r.out).contains(L("neuere Änderungen")) {
                    if Git.run(["rebase", "origin/" + branch], in: dir, timeout: 120).code == 0 {
                        r = Git.run(["push", "origin", "HEAD:refs/heads/" + branch], in: dir, timeout: 120)
                    } else {
                        Git.run(["rebase", "--abort"], in: dir, timeout: 30)
                    }
                }
                ok = r.code == 0; msg = ok ? String(format: L("Korrektur auf %@ hochgeladen"), branch) : r.out
                number = t.pr
                if ok { Worktrees.discard(wt, keepBranch: false) }
            } else {
                (ok, msg) = Worktrees.pullRequest(wt, title: t.title, body: body)
                number = msg.split(separator: "/").last.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            DispatchQueue.main.async {
                if ok {
                    self.finishMission(mid, outcome: "pr")
                    self.update(id) { p in
                        if let i = p.tasks.firstIndex(where: { $0.id == t.id }) {
                            p.tasks[i].pr = number
                            p.tasks[i].note = number.map { String(format: L("PR #%d offen – wird nach grüner CI und Review gemergt"), $0) } ?? msg
                        }
                        p.greenStreak += 1
                        p.lastPRScan = nil            // gleich nachsehen
                    }
                    self.say(id, "system", "⬆︎ " + (number.map { String(format: L("Pull Request #%d: "), $0) } ?? "") + t.title)
                } else {
                    let why = GitError.explain(msg)
                    // Automatisch reparieren: derselbe Agent bessert in derselben Arbeitskopie nach (einmal), danach wird neu geliefert
                    let tried = (t.prRetry ?? 0) >= 1
                    if !tried, let rec = MissionStore.shared.mission(mid), let agents = self.agents, let hub = self.hub {
                        let fix = AutoPR.fixMessage(why)
                        Handoff.continueMission(rec, message: fix, target: rec.agent, agents: agents, hub: hub, note: L("PR-Problem automatisch beheben")) { s in
                            self.update(id) { p in
                                if let i = p.tasks.firstIndex(where: { $0.id == t.id }) {
                                    p.tasks[i].state = .running; p.tasks[i].missionID = s.id.uuidString
                                    p.tasks[i].started = Date()     // der neue Lauf zählt ab jetzt, nicht ab dem ersten Start
                                    p.tasks[i].prRetry = (p.tasks[i].prRetry ?? 0) + 1
                                    p.tasks[i].note = "🔧 " + L("PR-Problem wird automatisch behoben: ") + why
                                }
                            }
                        }
                        self.say(id, "status", "🔧 " + L("PR ging nicht – Agent behebt das selbst: ") + t.title)
                    } else {
                        self.update(id) { p in if let i = p.tasks.firstIndex(where: { $0.id == t.id }) { p.tasks[i].note = "⚠️ " + why } }
                        self.say(id, "system", "✋ " + L("Konnte keinen Pull Request erstellen: ") + why)
                    }
                }
            }
        }
    }

    /// Offline fertig gewordene Arbeit hochladen, sobald wieder Internet da ist.
    func uploadOfflineWork(_ id: String) {
        guard LocalFirst.shared.isOnline, let p = project(id) else { return }
        for t in p.tasks where t.offlineWT != nil {
            guard let wt = t.offlineWT, let mid = t.offlineMid else { continue }
            update(id) { q in
                if let i = q.tasks.firstIndex(where: { $0.id == t.id }) { q.tasks[i].offlineWT = nil; q.tasks[i].offlineMid = nil }
            }
            guard FileManager.default.fileExists(atPath: Worktrees.top(wt)) else { continue }
            var u = t; u.offlineWT = nil; u.offlineMid = nil
            say(id, "status", "📡 " + L("Internet wieder da – lade hoch: ") + t.title)
            deliverPR(id, task: u, mid: mid, wt: wt)
        }
    }

    // MARK: Offene PRs beobachten

    /// Mehrere Klone desselben GitHub-Repos in Betreuung? Dann wacht nur einer (der zuerst übernommene) über GitHub –
    /// sonst würden PRs doppelt geprüft, kommentiert und repariert.
    func githubWatcher(for id: String) -> StewardProject? {
        guard let p = project(id), let slug = p.repoSlug else { return nil }
        return projects.filter { $0.repoSlug == slug }.min { $0.created < $1.created }
    }
    func isGitHubWatcher(_ id: String) -> Bool { githubWatcher(for: id)?.id == id }

    func scanPRs(_ id: String, force: Bool = false) {
        // Pausiert (auch frisch wiederhergestellt): nichts auf GitHub tun – keine Reviews, keine Kommentare, keine Korrekturen
        guard let p = project(id), p.hasGitHub, (p.github ?? true), !p.paused else { return }
        guard isGitHubWatcher(id) else { if p.prs != nil { update(id) { $0.prs = nil } }; return }
        let every: TimeInterval = Energy.saving ? 1800 : 600
        guard force || (p.lastPRScan.map { Date().timeIntervalSince($0) > every } ?? true) else { return }
        update(id) { $0.lastPRScan = Date() }
        let baseBranch = p.prBase ?? p.setup?.defaultBranch ?? ""
        DispatchQueue.global(qos: .utility).async {
            guard GH.ready else { return }
            // Lokalen Haupt-Branch aktuell halten (wie „automatisch holen“) – nur vorspulen, dein Arbeits-Branch bleibt unberührt
            GitSync.refreshBase(repo: id, base: baseBranch)
            let r = Proc.zsh("gh pr list --state open --limit 30 --json number,title,url,headRefName,headRefOid,baseRefName,isDraft,mergeable,author,statusCheckRollup",
                             in: id, timeout: 60)
            guard r.code == 0, let a = r.out.firstIndex(of: "["),
                  let arr = try? JSONSerialization.jsonObject(with: Data(r.out[a...].utf8)) as? [[String: Any]] else { return }
            let found: [StewardPR] = arr.compactMap { j in
                guard let n = j["number"] as? Int else { return nil }
                let checks = (j["statusCheckRollup"] as? [[String: Any]]) ?? []
                let states = checks.map { (($0["conclusion"] as? String) ?? ($0["state"] as? String) ?? ($0["status"] as? String) ?? "").uppercased() }
                // Abgebrochene/übersprungene Checks (z. B. Vorschau-Umgebungen am Limit) sind kein Fehler im Code
                let ci: String = checks.isEmpty ? "none"
                    : states.contains { ["FAILURE", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains($0) } ? "red"
                    : states.allSatisfy { ["SUCCESS", "NEUTRAL", "SKIPPED", "CANCELLED", "STALE"].contains($0) } ? "green" : "pending"
                let branch = j["headRefName"] as? String ?? ""
                return StewardPR(number: n, title: j["title"] as? String ?? "", url: j["url"] as? String ?? "", branch: branch,
                                 sha: j["headRefOid"] as? String ?? "", author: (j["author"] as? [String: Any])?["login"] as? String ?? "",
                                 draft: j["isDraft"] as? Bool ?? false, ours: branch.hasPrefix("aos/"), ci: ci,
                                 mergeable: j["mergeable"] as? String ?? "UNKNOWN", base: j["baseRefName"] as? String)
            }
            DispatchQueue.main.async { self.mergeScan(id, found) }
        }
    }

    private func mergeScan(_ id: String, _ found: [StewardPR]) {
        let openNumbers = Set(found.map(\.number))
        // Aufgaben, deren PR nicht mehr offen ist (gemergt oder geschlossen): erledigt
        update(id) { p in
            let old = Dictionary(uniqueKeysWithValues: (p.prs ?? []).map { ($0.number, $0) })
            p.prs = found.map { f in
                var x = f
                if let o = old[f.number] {
                    x.reviewedSha = o.reviewedSha; x.fixedSha = o.fixedSha; x.fixCount = o.fixCount
                    x.rerunSha = o.rerunSha; x.cleanedSha = o.cleanedSha; x.lookSha = o.lookSha   // sonst alle 10 min erneut
                    x.identitySha = o.identitySha
                    x.reviewing = o.reviewing            // läuft schon ein Review → nicht noch eins starten
                    if o.reviewedSha == f.sha { x.reviewOK = o.reviewOK; x.risk = o.risk; x.summary = o.summary; x.issues = o.issues }
                }
                return x
            }
            for i in p.tasks.indices where p.tasks[i].state == .review && p.tasks[i].pr != nil && !openNumbers.contains(p.tasks[i].pr!) {
                p.tasks[i].state = .done
                p.tasks[i].note = String(format: L("PR #%d ist nicht mehr offen (gemergt oder geschlossen)"), p.tasks[i].pr!)
            }
            // Korrekturen für PRs, die inzwischen geschlossen oder gemergt sind, nicht mehr starten
            for i in p.tasks.indices where [.queued, .idea].contains(p.tasks[i].state) && p.tasks[i].prBranch != nil
                && p.tasks[i].pr.map({ !openNumbers.contains($0) }) == true {
                p.tasks[i].state = .dropped
                p.tasks[i].note = String(format: L("PR #%d ist nicht mehr offen – Korrektur entfällt"), p.tasks[i].pr!)
            }
        }
        // Läuft noch eine Korrektur für einen PR, der inzwischen zu ist? Stoppen – sie bringt nichts mehr und kostet nur Tokens
        let stale = (project(id)?.tasks ?? []).filter { $0.state == .running && $0.prBranch != nil && $0.pr.map({ !openNumbers.contains($0) }) == true }
        if !stale.isEmpty {
            for t in stale {
                if let mid = t.missionID, let s = agents?.sessions.first(where: { $0.id.uuidString == mid && $0.running }) { agents?.close(s.id) }
            }
            let ids = Set(stale.map(\.id))
            update(id) { q in
                for i in q.tasks.indices where ids.contains(q.tasks[i].id) {
                    q.tasks[i].state = .dropped
                    q.tasks[i].note = String(format: L("PR #%d ist nicht mehr offen – Korrektur gestoppt"), q.tasks[i].pr ?? 0)
                }
            }
            say(id, "status", "🧹 " + String(format: L("%d Korrekturen für geschlossene PRs gestoppt."), stale.count))
        }
        guard let p = project(id) else { return }
        let target = p.prBase ?? p.setup?.defaultBranch ?? "main"
        // Eigene PRs mit falschem Ziel-Branch weder prüfen noch nachbessern (kostet nur Tokens) – sie werden geschlossen und neu geplant
        let blocked = Set((p.prs ?? []).filter { $0.ours && ($0.base ?? target) != target }.map(\.number))
        if !blocked.isEmpty {
            update(id) { q in
                for i in q.tasks.indices where [.queued, .idea].contains(q.tasks[i].state) && q.tasks[i].pr.map(blocked.contains) == true {
                    q.tasks[i].state = .dropped
                    q.tasks[i].note = L("PR zielt auf den falschen Branch – wird geschlossen und neu geplant, keine Korrektur nötig")
                }
            }
        }
        for pr in p.prs ?? [] where !pr.draft && !blocked.contains(pr.number) {
            if pr.mergeable == "CONFLICTING" { decide(id, pr); continue }   // erst Konflikt lösen, dann prüfen
            if pr.reviewedSha != pr.sha, pr.reviewing != true { review(id, pr); continue }
            decide(id, pr)
        }
    }

    // MARK: Review

    static var mergeNoted: [String: String] = [:]

    func review(_ id: String, _ pr: StewardPR) {
        setPR(id, pr.number) { $0.reviewing = true }
        let goal = project(id)?.goal ?? ""
        let post = project(id)?.postReviews ?? true
        DispatchQueue.global(qos: .utility).async {
            // Diff lokal berechnen: nur die eigenen Änderungen des PRs gegenüber seinem Ziel-Branch (keine 300-Dateien-Grenze von GitHub)
            let base = pr.base ?? Steward.shared.project(id)?.setup?.defaultBranch ?? "main"
            let ref = "refs/salenta/pr/\(pr.number)"
            _ = Git.run(["fetch", "--quiet", "--force", "origin", "pull/\(pr.number)/head:\(ref)", "+refs/heads/\(base):refs/remotes/origin/\(base)"], in: id, timeout: 120)
            let stat = Git.run(["diff", "--stat", "origin/\(base)...\(ref)"], in: id, timeout: 60).out
            // Erzeugte Dateien (Lockfiles, Snapshots, Karten) füllen sonst den Platz, und der eigentliche Code wird abgeschnitten
            var diff = Git.run(["diff", "origin/\(base)...\(ref)", "--", "."] + Self.reviewNoise.map { ":(exclude)" + $0 }, in: id, timeout: 90).out
            if diff.isEmpty { diff = Git.run(["diff", "origin/\(base)...\(ref)"], in: id, timeout: 90).out }
            if diff.isEmpty { diff = Proc.zsh("gh pr diff \(pr.number)", in: id, timeout: 90).out }
            diff = "FILES:\n" + String(stat.suffix(4000)) + "\n\nPATCH:\n" + diff
            // Der Prüfer bekommt den Stand des PRs als Arbeitskopie: Was im Patch abgeschnitten ist oder Kontext braucht, liest er nach,
            // statt „im Diff nicht erkennbar“ als Einwand zu melden (das kostete Korrekturrunden ohne echten Fehler).
            let checkout = Worktrees.root.appendingPathComponent("review-\(pr.number)-\(String(pr.sha.prefix(7)))").path
            Git.run(["worktree", "remove", "--force", checkout], in: id, timeout: 30)   // Rest eines abgebrochenen Reviews
            let hasCheckout = Git.run(["worktree", "add", "--detach", checkout, ref], in: id, timeout: 90).code == 0
            defer { if hasCheckout { Git.run(["worktree", "remove", "--force", checkout], in: id, timeout: 60) } }
            let lang = Profile.languageCode == "de" ? "German (plain, short)" : "English"
            let prompt = """
            You are a strict senior reviewer for the repository at \(id). Project goal: \(goal.isEmpty ? "-" : goal)
            Pull request #\(pr.number) "\(pr.title)" by \(pr.author), CI: \(pr.ci), mergeable: \(pr.mergeable).
            Review the diff for: correctness and obvious bugs, security (secrets, injection, auth), data loss, breaking changes,
            missing tests for risky logic, and whether it does what the title says. Ignore style nitpicks.
            CI is checked separately – do NOT reject because CI is still running or red.
            \(hasCheckout ? "You are inside a checkout of this pull request's head. If the patch below is cut off, or you need context to be sure, open the files (Read, Grep, Glob) before you judge." : "If the diff is truncated, judge the visible part.")
            Report only defects you have verified. Never list something as an issue because it "is not visible in the diff", "could not be \
            checked" or "may be missing" – look it up in the files; if you still cannot verify it, leave it out. Never reject because of truncation.
            Reject ("ok": false) only for concrete problems you can point to (file:line).
            "ok": true only if it is safe to merge as is. "risk": low | medium | high.
            Agents never get API keys, tokens or hosting settings. Missing configuration only the owner can add (e.g. an API key in the
            hosting environment, a real delivery test against a live account) is NOT a reason to reject when the code handles its absence
            safely – mention it in "summary" as an owner step instead.
            Answer ONLY with JSON in \(lang): {"ok":true,"risk":"low","summary":"one or two sentences","issues":["file:line – problem – fix"]}

            DIFF (may be truncated):
            \(String(diff.prefix(120_000)))
            """
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("aos-prreview-\(UUID().uuidString).md")
            try? prompt.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            var j: [String: Any]?
            func parse(_ res: String) -> [String: Any]? {
                guard let a = res.firstIndex(of: "{"), let b = res.lastIndex(of: "}"), a < b else { return nil }
                return try? JSONSerialization.jsonObject(with: Data(res[a...b].utf8)) as? [String: Any]
            }
            // Claude pausiert, im Limit oder knapp → nicht Opus verbrennen; scheitert Claude, prüft Codex (sonst bleibt der PR ewig liegen)
            let claudeOff = Usage.isPaused(.claude) || (Usage.shared.blocked["claude"] ?? .distantPast) > Date()
            let claudeModels = claudeOff ? [] : (Usage.shared.isTight(.claude) ? ["sonnet"] : ["opus", "sonnet"])
            for model in claudeModels {
                var r = hasCheckout
                    ? Proc.zsh("claude -p --model \(model) --output-format json --max-turns 12 --allowedTools Read,Grep,Glob --strict-mcp-config < \(Shell.quote(file.path))",
                               in: checkout, timeout: 600)
                    : (out: "", code: Int32(1))
                // Ohne Arbeitskopie – oder die Runden reichten nicht: nur mit dem Patch im Prompt
                if Verifier.claudeResult(r.out) == nil, Verifier.claudeFailure(r.out, code: r.code) != L("Claude ist im Limit") {
                    r = Proc.zsh("claude -p --model \(model) --output-format json --max-turns 3 --strict-mcp-config < \(Shell.quote(file.path))",
                                 in: NSTemporaryDirectory(), timeout: 420)
                }
                if let res = Verifier.claudeResult(r.out), let a = res.firstIndex(of: "{"), let b = res.lastIndex(of: "}"), a < b,
                   let x = try? JSONSerialization.jsonObject(with: Data(res[a...b].utf8)) as? [String: Any] { j = x; break }
                if Verifier.claudeFailure(r.out, code: r.code) == L("Claude ist im Limit") { break }
            }
            if j == nil, Detection.which("codex") != nil, !Usage.isPaused(.codex) {
                let outFile = FileManager.default.temporaryDirectory.appendingPathComponent("aos-prreview-\(UUID().uuidString).txt")
                let F = CLIFlags.shared
                let oFlag = F.pick(.codex, sub: "exec", ["-o", "--output-last-message"])
                let opts = F.pick(.codex, sub: "exec", ["-s read-only", "--sandbox read-only"]) + F.pick(.codex, sub: "exec", ["--skip-git-repo-check"])
                    + (oFlag.isEmpty ? "" : oFlag + " " + Shell.quote(outFile.path))
                let r = Proc.zsh("codex exec\(opts) - < \(Shell.quote(file.path))", in: hasCheckout ? checkout : NSTemporaryDirectory(), timeout: 420)
                j = parse((try? String(contentsOf: outFile, encoding: .utf8)) ?? r.out)
                try? FileManager.default.removeItem(at: outFile)
            }
            guard let j else { DispatchQueue.main.async { self.setPR(id, pr.number) { $0.reviewing = nil } }; return }
            let ok = j["ok"] as? Bool ?? false, risk = j["risk"] as? String ?? "medium"
            let summary = j["summary"] as? String ?? "", issues = (j["issues"] as? [String]) ?? []
            if post {
                let body = "🧭 **" + L("Review vom Projekt-Betreuer (Salenta Code)") + "** – " + (ok ? "✅ " + L("bereit zum Mergen") : "⚠️ " + L("bitte nachbessern"))
                    + " · " + L("Risiko") + ": \(risk)\n\n\(summary)" + (issues.isEmpty ? "" : "\n\n" + issues.map { "- " + $0 }.joined(separator: "\n"))
                let bf = FileManager.default.temporaryDirectory.appendingPathComponent("aos-prcomment-\(UUID().uuidString).md")
                try? body.write(to: bf, atomically: true, encoding: .utf8)
                _ = Proc.zsh("gh pr comment \(pr.number) --body-file \(Shell.quote(bf.path))", in: id, timeout: 60)
                try? FileManager.default.removeItem(at: bf)
                // Projekte mit Vier-Augen-Regel (.github/gegenpruefung-pfade.txt): das Review hier IST die unabhängige Prüfung
                // durch einen anderen Agent ohne Umsetzungsverlauf – also Label setzen und den erwarteten Kommentar schreiben,
                // sonst bleibt die CI rot, obwohl geprüft wurde.
                if ok, risk != "high", FileManager.default.fileExists(atPath: (id as NSString).appendingPathComponent(".github/gegenpruefung-pfade.txt")) {
                    let gf = FileManager.default.temporaryDirectory.appendingPathComponent("aos-prgegen-\(UUID().uuidString).md")
                    try? ("Gegenprüfung: bestanden – " + L("unabhängiges Review durch den Projekt-Betreuer (anderer Agent, frischer Kontext). ") + summary).write(to: gf, atomically: true, encoding: .utf8)
                    _ = Proc.zsh("gh label create gegengeprueft --color 0e8a16 --description 'Unabhängig gegengeprüft' 2>/dev/null; gh pr comment \(pr.number) --body-file \(Shell.quote(gf.path)) && gh pr edit \(pr.number) --add-label gegengeprueft", in: id, timeout: 90)
                    try? FileManager.default.removeItem(at: gf)
                }
            }
            DispatchQueue.main.async {
                self.setPR(id, pr.number) { x in
                    x.reviewing = nil; x.reviewedSha = pr.sha; x.reviewOK = ok; x.risk = risk; x.summary = summary; x.issues = issues
                }
                self.say(id, "system", (ok ? "✅ " : "⚠️ ") + String(format: L("PR #%d geprüft: "), pr.number) + (summary.isEmpty ? pr.title : summary))
                if let fresh = self.project(id)?.prs?.first(where: { $0.number == pr.number }) { self.decide(id, fresh) }
            }
        }
    }

    // MARK: Mergen oder nachbessern

    private func decide(_ id: String, _ pr: StewardPR) {
        // Konflikt braucht kein Review vorab – sonst wartet die Korrektur auf ein Review, das evtl. nie kommt (Limit)
        guard let p = project(id), pr.reviewedSha == pr.sha || pr.mergeable == "CONFLICTING" else { return }
        let allowed = p.mergesPRs && (pr.ours || p.mergeAll == true)
        if allowed, pr.changesLook, pr.reviewOK == true, pr.ci == "green" || pr.ci == "none", pr.mergeable != "CONFLICTING" {
            if pr.lookSha != pr.sha {
                update(id) { q in if let i = q.prs?.firstIndex(where: { $0.number == pr.number }) { q.prs?[i].lookSha = pr.sha } }
                say(id, "betreuer", String(format: L("🎨 PR #%d verändert das Aussehen – das übernehme ich nicht selbst. Schau dir die Vorschau an und klick bei den PRs auf „Mergen“, wenn es dir gefällt: %@"), pr.number, pr.url))
            }
            return
        }
        if pr.reviewOK == true, pr.risk != "high", pr.ci == "green" || pr.ci == "none", pr.mergeable != "CONFLICTING", allowed, !p.paused {
            DispatchQueue.global(qos: .userInitiated).async {
                let (ok, msg) = GitSync.mergePR(repo: id, number: pr.number)
                DispatchQueue.main.async {
                    // Fehlversuche (z. B. „Review vorgeschrieben“) nur einmal je PR-Stand melden – es wird still weiter versucht
                    let key = "\(id)#\(pr.number)@\(pr.sha)"
                    if ok || Self.mergeNoted[key] != msg { self.say(id, "system", (ok ? "🎉 " : "") + msg) }
                    if !ok { Self.mergeNoted[key] = msg }
                    if ok {
                        Celebration.shared.fire(String(format: L("PR #%d gemergt"), pr.number), pr.title, symbol: "arrow.triangle.merge", tint: .purple)
                        self.update(id) { q in
                            q.prs?.removeAll { $0.number == pr.number }
                            for i in q.tasks.indices where q.tasks[i].pr == pr.number { q.tasks[i].state = .done; q.tasks[i].note = String(format: L("PR #%d gemergt"), pr.number) }
                        }
                        self.update(id) { $0.lastCI = Date().addingTimeInterval(-800) }   // CI auf dem Haupt-Branch gleich nach dem Merge prüfen
                    }
                }
            }
            return
        }
        // Eigener PR mit roter CI, Konflikt oder Review-Einwänden → Korrektur direkt auf dem PR-Branch (einmal pro Stand)
        let broken = pr.ci == "red" || pr.mergeable == "CONFLICTING" || pr.reviewOK == false
        // Rot, weil GitHub den letzten Commit keinem Konto zuordnet (Vorschau-Dienste wie Vercel verweigern dann den Aufbau)?
        // Das kann kein Helfer im Code beheben. Der Betreuer setzt selbst einen leeren Commit mit deinem GitHub-Konto obendrauf.
        if pr.ours, pr.ci == "red", pr.mergeable != "CONFLICTING", pr.identitySha != pr.sha {
            setPR(id, pr.number) { $0.identitySha = pr.sha }
            DispatchQueue.global(qos: .utility).async {
                guard let new = Self.reattribute(repo: id, pr: pr) else {
                    // Commit ist zugeordnet – die rote CI hat einen anderen Grund: gleich normal weiter entscheiden
                    DispatchQueue.main.async { if let cur = self.project(id)?.prs?.first(where: { $0.number == pr.number }), cur.sha == pr.sha { self.decide(id, cur) } }
                    return
                }
                DispatchQueue.main.async {
                    self.say(id, "system", "🪪 " + String(format: L("PR #%d: Die Vorschau war blockiert, weil der letzte Commit keinem GitHub-Konto zugeordnet war. Ich habe ihn deinem Konto zugeordnet – die Prüfungen laufen neu, kein Code-Problem."), pr.number))
                    self.setPR(id, pr.number) { x in
                        // gleicher Inhalt, neuer Stand: Review und Merker mitnehmen statt alles noch einmal zu prüfen
                        if x.reviewedSha == pr.sha { x.reviewedSha = new }
                        if x.lookSha == pr.sha { x.lookSha = new }
                        if x.cleanedSha == pr.sha { x.cleanedSha = new }
                        x.sha = new; x.identitySha = new; x.ci = "pending"
                    }
                    // Eine schon eingereihte „CI ist rot“-Korrektur für diesen PR entfällt
                    self.update(id) { q in
                        for i in q.tasks.indices where q.tasks[i].pr == pr.number && q.tasks[i].prBranch != nil && q.tasks[i].source == "ci"
                            && [.queued, .idea].contains(q.tasks[i].state) && Self.isCIFix(q.tasks[i].detail) {
                            q.tasks[i].state = .dropped
                            q.tasks[i].note = L("Vorschau war nur wegen der Commit-Zuordnung blockiert – selbst behoben, keine Korrektur nötig")
                        }
                    }
                }
            }
            return
        }
        // Rote CI durch die Infrastruktur (Download-Fehler 5xx, Runner abgebrochen, Rate-Limit)? Dann kein Helfer, sondern einmal neu starten.
        if pr.ci == "red", pr.mergeable != "CONFLICTING", pr.reviewOK != false, pr.rerunSha != pr.sha {
            setPR(id, pr.number) { $0.rerunSha = pr.sha }
            DispatchQueue.global(qos: .utility).async {
                if Self.rerunIfInfrastructure(repo: id, sha: pr.sha) {
                    DispatchQueue.main.async {
                        self.say(id, "system", "↻ " + String(format: L("PR #%d: CI war wegen eines GitHub-/Download-Fehlers rot – neu gestartet, kein Code-Problem."), pr.number))
                        self.setPR(id, pr.number) { $0.ci = "pending"; $0.fixedSha = pr.sha }
                    }
                }
            }
            return
        }
        // Debug-Ablagen (Playwright-Screenshots, Logs) im PR? Das räumt der Betreuer selbst auf – kein Helfer, keine Korrekturrunde
        if pr.ours, pr.cleanedSha != pr.sha {
            setPR(id, pr.number) { $0.cleanedSha = pr.sha }
            let hasNoise = (pr.issues ?? []).contains { i in Worktrees.debugDirs.contains { i.contains($0) } }
            DispatchQueue.global(qos: .utility).async {
                if Self.removeDebugFiles(repo: id, pr: pr) {
                    DispatchQueue.main.async {
                        self.say(id, "system", "🧹 " + String(format: L("PR #%d: Debug-Dateien des Prüfwerkzeugs entfernt – Review und CI laufen neu."), pr.number))
                        self.setPR(id, pr.number) { $0.reviewOK = nil; $0.reviewedSha = nil; $0.ci = "pending" }
                    }
                }
            }
            if hasNoise { return }   // sonst normal weiter: Merge oder Korrektur
        }
        // Die Korrektur für diesen Stand ist gescheitert oder verworfen worden, ohne den PR zu ändern? Dann darf der Wächter es noch
        // einmal versuchen – sonst bliebe der PR für immer liegen (der Planer darf PR-Korrekturen nicht selbst einreihen).
        let retry = Self.fixFailed(p.tasks, pr: pr.number)
        if pr.ours, broken, pr.fixedSha != pr.sha || retry, (pr.fixCount ?? 0) < 2, Energy.backgroundAgentsOK, !p.paused {
            setPR(id, pr.number) { $0.fixedSha = pr.sha; $0.fixCount = ($0.fixCount ?? 0) + 1 }
            let why = pr.mergeable == "CONFLICTING" ? L("Konflikt mit dem Haupt-Branch – neuesten Stand einarbeiten (rebase/merge) und Konflikte lösen.")
                : pr.ci == "red" ? L("Die CI auf GitHub ist rot. Lies die Logs mit `gh pr checks` und `gh run view --log-failed` und behebe die Ursache.")
                : L("Das Review hat Einwände:") + "\n" + (pr.issues ?? []).map { "- " + $0 }.joined(separator: "\n")
            update(id) { q in
                // Schon eine offene Korrektur für diesen PR? Dann nur aktualisieren – nie doppelt einreihen
                if let j = q.tasks.firstIndex(where: { $0.pr == pr.number && [.idea, .queued, .running].contains($0.state) }) {
                    if q.tasks[j].state != .running { q.tasks[j].detail = why; q.tasks[j].ref = pr.url + "@" + pr.sha }
                    return
                }
                q.tasks.append(StewardTask(title: String(format: L("PR #%d nachbessern: "), pr.number) + pr.title, detail: why,
                                           state: q.trust == 0 ? .idea : .queued, source: "ci", priority: 1, ref: pr.url + "@" + pr.sha,
                                           pr: pr.number, prBranch: pr.branch))
            }
            say(id, "system", "🔧 " + String(format: L("PR #%d braucht eine Korrektur – Aufgabe eingereiht."), pr.number))
            dispatch(id)
        } else if pr.ours, broken, (pr.fixCount ?? 0) >= 2, pr.fixedSha != pr.sha || (retry && Self.mergeNoted["stuck#\(id)#\(pr.number)@\(pr.sha)"] == nil) {
            setPR(id, pr.number) { $0.fixedSha = pr.sha }
            Self.mergeNoted["stuck#\(id)#\(pr.number)@\(pr.sha)"] = "1"
            say(id, "system", "✋ " + String(format: L("PR #%d ist nach 2 Korrekturen noch nicht grün – bitte selbst ansehen (Auf GitHub) oder über „Alle prüfen …“ entscheiden."), pr.number))
        } else if !pr.ours, pr.reviewOK != nil, !allowed, pr.reviewedSha == pr.sha, pr.summary != nil {
            // fremder PR: nur Bescheid sagen (einmal je Stand – über reviewedSha schon abgedeckt)
        }
    }

    /// Erzeugte Dateien, die im Review-Patch nichts verloren haben (sie stehen weiter in der Dateiliste).
    static let reviewNoise = ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "Cargo.lock", "Podfile.lock", "composer.lock",
                              "*.snap", "*.map", "*.min.js", "*.min.css", "*.svg", "*.lock"]

    /// Ist die letzte Korrektur für diesen PR gescheitert oder verworfen worden (und läuft keine mehr)? Von dir gestoppte zählen nicht.
    static func fixFailed(_ tasks: [StewardTask], pr number: Int) -> Bool {
        let fixes = tasks.filter { $0.pr == number && $0.prBranch != nil }
        guard let last = fixes.last, !fixes.contains(where: { [.idea, .queued, .running, .review].contains($0.state) }) else { return false }
        if last.state == .red { return true }
        return last.state == .dropped && last.note != L("von dir gestoppt")
    }

    /// Korrektur-Aufgabe, die nur wegen roter CI entstand (nicht wegen Konflikt oder Review-Einwänden)?
    static func isCIFix(_ detail: String) -> Bool {
        let d = detail.lowercased()
        return d.contains("gh pr checks") && !d.contains("konflikt") && !d.contains("conflict")
    }

    /// Ist der letzte Commit des PRs keinem GitHub-Konto zugeordnet, einen leeren Commit mit deinem Konto obendrauf setzen
    /// (Vorschau-Dienste prüfen den Autor des letzten Commits). Liefert den neuen Stand – nil, wenn nichts zu tun war.
    static func reattribute(repo: String, pr: StewardPR) -> String? {
        guard GH.ready, !pr.branch.isEmpty, !pr.sha.isEmpty, let who = Git.githubIdentityWait() else { return nil }
        let r = Proc.zsh("gh api " + Shell.quote("repos/{owner}/{repo}/commits/" + pr.sha) + " --jq '.author.login // \"\"' 2>/dev/null", in: repo, timeout: 30)
        guard r.code == 0, r.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }   // zugeordnet oder nicht prüfbar
        let tmp = Worktrees.root.appendingPathComponent("konto-\(pr.number)-\(String(pr.sha.prefix(7)))").path
        defer { Git.run(["worktree", "remove", "--force", tmp], in: repo, timeout: 60) }
        guard Git.run(["fetch", "--quiet", "origin", pr.branch], in: repo, timeout: 120).code == 0,
              Git.run(["worktree", "add", "--detach", tmp, "origin/" + pr.branch], in: repo, timeout: 60).code == 0,
              Git.run(["rev-parse", "HEAD"], in: tmp).out.trimmingCharacters(in: .whitespacesAndNewlines) == pr.sha else { return nil }
        guard Git.run(["-c", "user.name=\(who.name)", "-c", "user.email=\(who.email)", "commit", "-q", "--allow-empty", "-m",
                       L("Vorschau neu anstoßen: Commit dem GitHub-Konto zugeordnet")], in: tmp).code == 0 else { return nil }
        let new = Git.run(["rev-parse", "HEAD"], in: tmp).out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard new.count >= 7, new != pr.sha, Git.run(["push", "origin", "HEAD:refs/heads/" + pr.branch], in: tmp, timeout: 120).code == 0 else { return nil }
        return new
    }

    /// Enthält der PR Debug-Ablagen (.playwright-mcp, playwright-report)? Dann in einer kurzlebigen Arbeitskopie entfernen und hochladen.
    static func removeDebugFiles(repo: String, pr: StewardPR) -> Bool {
        let files = Proc.zsh("gh pr view \(pr.number) --json files --jq '.files[].path'", in: repo, timeout: 60).out
            .split(separator: "\n").map(String.init)
        let noise = files.filter { f in Worktrees.debugDirs.contains { f.hasPrefix($0 + "/") || f.contains("/" + $0 + "/") } }
        guard !noise.isEmpty, !pr.branch.isEmpty else { return false }
        let tmp = Worktrees.root.appendingPathComponent("clean-\(pr.number)-\(String(pr.sha.prefix(7)))").path
        defer { Git.run(["worktree", "remove", "--force", tmp], in: repo, timeout: 60) }
        guard Git.run(["fetch", "--quiet", "origin", pr.branch], in: repo, timeout: 120).code == 0,
              Git.run(["worktree", "add", "--detach", tmp, "origin/" + pr.branch], in: repo, timeout: 60).code == 0 else { return false }
        Git.run(["rm", "-r", "-q", "--cached", "--ignore-unmatch", "--"] + Worktrees.debugDirs, in: tmp)
        for d in Worktrees.debugDirs { try? FileManager.default.removeItem(atPath: (tmp as NSString).appendingPathComponent(d)) }
        guard Git.run(["diff", "--cached", "--quiet"], in: tmp).code != 0 else { return false }
        guard Git.run(Git.identity(tmp) + ["commit", "-q", "-m", L("Debug-Dateien des Prüfwerkzeugs entfernt")], in: tmp).code == 0 else { return false }
        return Git.run(["push", "origin", "HEAD:refs/heads/" + pr.branch], in: tmp, timeout: 120).code == 0
    }

    /// Fehlgeschlagene Läufe zu diesem Commit ansehen: scheitern sie nur an der Infrastruktur (Aktion konnte nicht geladen werden,
    /// HTTP 5xx, Runner verloren, Rate-Limit), werden sie neu gestartet. true = alle roten Läufe waren Infrastruktur.
    static func rerunIfInfrastructure(repo: String, sha: String) -> Bool {
        let list = Proc.zsh("gh run list --commit \(Shell.quote(sha)) --status failure --limit 10 --json databaseId", in: repo, timeout: 60).out
        guard let a = list.firstIndex(of: "["), let arr = try? JSONSerialization.jsonObject(with: Data(list[a...].utf8)) as? [[String: Any]], !arr.isEmpty else { return false }
        let infra = ["unexpected http response: 5", "http 502", "http 503", "http 504", "econnreset", "etimedout", "api rate limit",
                     "the runner has received a shutdown signal", "lost communication with the server", "failed to download action", "no space left on device"]
        var ids: [Int] = []
        for run in arr {
            guard let rid = run["databaseId"] as? Int else { continue }
            let log = Proc.zsh("gh run view \(rid) --log-failed 2>/dev/null | tail -c 20000", in: repo, timeout: 90).out.lowercased()
            guard !log.isEmpty, infra.contains(where: { log.contains($0) }) else { return false }
            ids.append(rid)
        }
        for rid in ids { _ = Proc.zsh("gh run rerun \(rid) --failed", in: repo, timeout: 60) }
        return !ids.isEmpty
    }

    func setPR(_ id: String, _ number: Int, _ change: (inout StewardPR) -> Void) {
        update(id) { p in if let i = p.prs?.firstIndex(where: { $0.number == number }) { change(&p.prs![i]) } }
    }

    /// Alte PRs mit falschem Ziel-Branch schließen (mit Begründung), danach neu planen lassen.
    func closeWrongBase(_ id: String, _ prs: [StewardPR], target: String, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var closed = 0, last = ""
            for pr in prs {
                let note = "🧭 " + String(format: L("Geschlossen vom Projekt-Betreuer: Dieser PR zielt auf „%@“ statt auf „%@“ und enthält dadurch fremde, nicht hochgeladene Commits. Das Thema wird sauber auf „%@“ neu umgesetzt. Der Branch bleibt erhalten."), pr.base ?? "?", target, target)
                let f = FileManager.default.temporaryDirectory.appendingPathComponent("aos-close-\(pr.number).md")
                try? note.write(to: f, atomically: true, encoding: .utf8)
                let r = Proc.zsh("gh pr close \(pr.number) --comment \"$(cat \(Shell.quote(f.path)))\"", in: id, timeout: 60)
                try? FileManager.default.removeItem(at: f)
                if r.code == 0 { closed += 1 } else { last = GitError.explain(r.out) }
            }
            DispatchQueue.main.async {
                self.say(id, "status", "🧹 " + String(format: L("%d alte Pull Requests geschlossen."), closed))
                self.scanPRs(id, force: true)
                let titles = prs.map { "- " + $0.title }.joined(separator: "\n")
                self.think(id, trigger: String(format: L("Diese PRs wurden geschlossen, weil sie auf den falschen Branch zielten. Plane die Themen, die noch nicht erledigt sind, sauber neu (sie werden jetzt auf „%@“ aufgebaut):"), target) + "\n" + titles)
                completion(closed == prs.count ? "✓ " + String(format: L("%d Pull Requests geschlossen – der Betreuer plant neu"), closed) : "⚠️ " + last)
            }
        }
    }

    func mergeNow(_ id: String, _ number: Int, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let (ok, msg) = GitSync.mergePR(repo: id, number: number)
            DispatchQueue.main.async {
                if ok { self.update(id) { q in q.prs?.removeAll { $0.number == number }
                    for i in q.tasks.indices where q.tasks[i].pr == number { q.tasks[i].state = .done } } }
                completion(msg)
            }
        }
    }
}

/// Tafel-Abschnitt „Pull Requests“ im Betreuer.
struct StewardPRSection: View {
    let id: String
    @ObservedObject private var steward = Steward.shared
    @EnvironmentObject private var app: AppModel
    @State private var open: Set<Int> = []
    @State private var closeWrong = false
    @AppStorage("steward.prGroupsCollapsed") private var collapsedRaw = "Fremde PRs|Entwürfe"

    /// PRs nach Stand gruppiert – so sieht man auf einen Blick, was zu tun ist.
    private func groups(_ prs: [StewardPR]) -> [(String, String, Color, [StewardPR])] {
        let ready = prs.filter { !$0.draft && ($0.ci == "green" || $0.ci == "none") && $0.mergeable == "MERGEABLE" && $0.reviewOK == true && $0.reviewedSha == $0.sha }
        let broken = prs.filter { !$0.draft && !ready.contains($0) && ($0.ci == "red" || $0.mergeable == "CONFLICTING" || ($0.reviewOK == false && $0.reviewedSha == $0.sha)) }
        let drafts = prs.filter(\.draft)
        let rest = prs.filter { !ready.contains($0) && !broken.contains($0) && !drafts.contains($0) }
        return [(L("Bereit zum Mergen"), "checkmark.circle.fill", .green, ready),
                (L("Braucht Korrektur"), "wrench.and.screwdriver.fill", .orange, broken),
                (L("Läuft noch (CI oder Prüfung)"), "clock.fill", .blue, rest),
                (L("Entwürfe"), "pencil.circle", .secondary, drafts)].filter { !$0.3.isEmpty }
    }

    var body: some View {
        if let p = steward.project(id), p.hasGitHub, !steward.isGitHubWatcher(id), let w = steward.githubWatcher(for: id) {
            HStack(spacing: Grid.s) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(String(format: L("Dieser Ordner ist ein weiterer Klon von %@. Um GitHub (Pull Requests, CI) kümmert sich der Betreuer im Ordner „%@“ – damit nichts doppelt passiert."),
                            p.repoSlug ?? "", (w.id as NSString).deletingLastPathComponent.components(separatedBy: "/").last ?? w.name))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L("Dorthin")) { app.page = .steward(w.id) }.controlSize(.small)
            }
        } else if let p = steward.project(id), p.hasGitHub {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Pull Requests (\(p.prs?.count ?? 0))").font(.headline)
                    Spacer()
                    if !GH.ready {
                        Text("GitHub CLI nicht angemeldet").font(.caption).foregroundStyle(.orange)
                    }
                    if (p.prs?.count ?? 0) > 1 {
                        Button { PRTriage.shared.open(id) } label: { Label(L("Alle prüfen …"), systemImage: "checklist") }.controlSize(.small)
                    }
                    Button { steward.scanPRs(id, force: true) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help(L("Jetzt auf GitHub nachsehen"))
                }
                let target = p.prBase ?? p.setup?.defaultBranch ?? "main"
                let wrong = (p.prs ?? []).filter { $0.ours && ($0.base ?? target) != target }
                if !wrong.isEmpty {
                    HStack(alignment: .top, spacing: Grid.s) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(String(format: L("%d Pull Requests des Betreuers zielen auf einen anderen Branch als „%@“ und enthalten dadurch fremde Commits. Schließen – der Betreuer plant die Themen sauber neu."), wrong.count, target))
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(L("Schließen und neu planen")) { closeWrong = true }
                            .controlSize(.small).buttonStyle(.borderedProminent).tint(.orange)
                    }
                    .padding(Grid.s).background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
                    .confirmationDialog(String(format: L("%d Pull Requests auf GitHub schließen?"), wrong.count), isPresented: $closeWrong) {
                        Button(L("Schließen und neu planen"), role: .destructive) { steward.closeWrongBase(id, wrong, target: target) { app.show($0) } }
                    } message: { Text(L("Jeder PR bekommt einen kurzen Kommentar mit dem Grund. Die Branches bleiben erhalten.")) }
                }
                if (p.prs ?? []).isEmpty {
                    Text(p.viaPR ? L("Keine offenen Pull Requests. Grüne Ergebnisse kommen als PR und werden nach grüner CI gemergt.") : L("Keine offenen Pull Requests."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(groups(p.prs ?? []), id: \.0) { g in
                    let collapsed = collapsedRaw.split(separator: "|").contains(Substring(g.0))
                    DisclosureGroup(isExpanded: Binding(get: { !collapsed }, set: { on in
                        var set = Set(collapsedRaw.split(separator: "|").map(String.init))
                        if on { set.remove(g.0) } else { set.insert(g.0) }
                        collapsedRaw = set.sorted().joined(separator: "|")
                    })) {
                        VStack(alignment: .leading, spacing: 4) { ForEach(g.3) { pr in row(pr, p) } }.padding(.top, 4)
                    } label: {
                        Label("\(g.0) (\(g.3.count))", systemImage: g.1).foregroundStyle(g.2).font(.callout.weight(.semibold))
                    }
                }
            }
        }
    }

    private func row(_ pr: StewardPR, _ p: StewardProject) -> some View {
        let isOpen = open.contains(pr.number)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: Grid.s) {
                Image(systemName: "arrow.triangle.pull").foregroundStyle(pr.ci == "red" ? .red : pr.ci == "green" ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("#\(pr.number) \(pr.title)").fontWeight(.medium).lineLimit(isOpen ? 3 : 1)
                    if isOpen { HStack(spacing: 6) {
                        Text(pr.ours ? L("vom Betreuer") : "@" + pr.author)
                        Text("· CI: " + ciText(pr.ci))
                        if pr.mergeable == "CONFLICTING" { Text("· " + L("Konflikt")).foregroundStyle(.orange) }
                        if pr.draft { Text("· " + L("Entwurf")) }
                        if pr.reviewing == true { Text("· " + L("wird geprüft …")) }
                        else if let ok = pr.reviewOK, pr.reviewedSha == pr.sha { Text("· " + (ok ? L("Review ok") : L("Review: Einwände"))).foregroundStyle(ok ? .green : .orange) }
                    }
                    .font(.caption).foregroundStyle(.tertiary) }
                    if isOpen, let s = pr.summary, pr.reviewedSha == pr.sha { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(8) }
                    if isOpen, let issues = pr.issues, !issues.isEmpty, pr.reviewedSha == pr.sha {
                        ForEach(issues.prefix(5), id: \.self) { Text("• " + $0).font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
                    }
                }
                Spacer()
                Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture { if isOpen { open.remove(pr.number) } else { open.insert(pr.number) } }
            if isOpen { HStack(spacing: 6) {
                Spacer()
                if let u = URL(string: pr.url) { Link(L("Auf GitHub"), destination: u) }
                Button(L("Neu prüfen")) { steward.review(id, pr) }.disabled(pr.reviewing == true)
                Button(L("Mergen")) { steward.mergeNow(id, pr.number) { app.show($0) } }
                    .buttonStyle(.borderedProminent).tint(.purple)
                    .disabled(pr.mergeable == "CONFLICTING" || pr.ci == "red" || pr.ci == "pending")
            }
            .controlSize(.small) }
        }
        .padding(.horizontal, Grid.s).padding(.vertical, isOpen ? Grid.s : 6)
        .background(ModernCardBackground(radius: 10, accent: false))
    }

    private func ciText(_ s: String) -> String {
        switch s { case "green": L("grün"); case "red": L("rot"); case "pending": L("läuft"); default: L("keine Checks") }
    }
}

// MARK: - Fehler verständlich erklären

/// Übersetzt Fehlermeldungen von git und der GitHub CLI in einen Satz: was passiert ist und was hilft.
enum GitError {
    static func explain(_ raw: String) -> String {
        let o = raw.lowercased()
        func has(_ s: String...) -> Bool { s.contains { o.contains($0) } }
        if has("gh013", "push protection", "secret scanning", "push cannot contain secrets") {
            return L("GitHub hat den Upload blockiert, weil in den Änderungen ein Schlüssel oder Passwort steckt. Der Wert muss aus dem Code raus (Umgebungsvariable), dann neu hochladen.")
        }
        if has("workflow` scope", "workflow scope", "without `workflow` scope") {
            return L("Die Änderung betrifft GitHub-Actions-Dateien (.github/workflows). Dafür braucht die GitHub-Anmeldung das Recht „workflow“: im Terminal einmal `gh auth refresh -s workflow` ausführen.")
        }
        if has("authentication failed", "could not read username", "gh auth login", "not logged into", "bad credentials", "401") {
            return L("Die GitHub-Anmeldung ist abgelaufen oder fehlt. Einmal neu anmelden: Einstellungen › Integrationen › GitHub oder `gh auth login`.")
        }
        if has("permission to", "403", "denied to", "not have permission", "must have push access", "resource not accessible") {
            return L("Dein GitHub-Konto darf in dieses Repo nicht schreiben. Prüfe, ob du Schreibrechte hast oder ob das Repo jemand anderem gehört (dann einen Fork nutzen).")
        }
        if has("protected branch", "gh006", "required status check", "at least 1 approving review", "review required", "branch protection") {
            return L("Der Branch ist auf GitHub geschützt: Bestimmte Prüfungen oder ein Review einer anderen Person sind Pflicht. Das lässt sich nur auf GitHub freigeben.")
        }
        if has("a pull request for branch", "already exists") {
            return L("Für diesen Branch gibt es schon einen Pull Request – es wurde nur der neue Stand hochgeladen.")
        }
        if has("no commits between", "must first push", "head sha can't be blank") {
            return L("Der Branch enthält keine neuen Änderungen gegenüber dem Haupt-Branch – es gibt nichts für einen Pull Request.")
        }
        if has("non-fast-forward", "fetch first", "updates were rejected", "stale info", "rejected") {
            return L("Auf GitHub gibt es inzwischen neuere Änderungen an diesem Branch. Erst den neuen Stand holen und einarbeiten, dann erneut hochladen.")
        }
        if has("merge conflict", "conflict", "not mergeable", "dirty") {
            return L("Konflikt: Dieselben Stellen wurden inzwischen auch im Haupt-Branch geändert. Ein Agent muss den neuen Stand einarbeiten und die Konflikte lösen.")
        }
        if has("large files", "gh001", "exceeds github's file size limit", "file size limit") {
            return L("Eine Datei ist zu groß für GitHub (über 100 MB). Sie muss aus dem Commit raus oder über Git LFS laufen.")
        }
        if has("could not resolve host", "network is unreachable", "timed out", "connection reset", "unable to access") {
            return L("Keine Verbindung zu GitHub (Internet oder GitHub gestört). Wird beim nächsten Durchlauf automatisch erneut versucht.")
        }
        if has("repository not found", "could not read from remote", "does not appear to be a git repository") {
            return L("Das GitHub-Repo wurde nicht gefunden – umbenannt, gelöscht oder die Adresse („origin“) stimmt nicht mehr.")
        }
        if has("no such remote", "no configured push destination", "origin") && has("not") {
            return L("Für dieses Projekt ist kein GitHub-Repo eingetragen („origin“ fehlt).")
        }
        if has("command not found: gh", "gh: command not found", "executable file not found") {
            return L("Die GitHub CLI (gh) ist nicht installiert – Einstellungen › Integrationen › GitHub.")
        }
        if has("rate limit", "secondary rate") {
            return L("GitHub bremst gerade (zu viele Anfragen). In ein paar Minuten klappt es wieder – wird automatisch erneut versucht.")
        }
        let last = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
        return L("GitHub/git meldet einen unbekannten Fehler") + (last.isEmpty ? "." : ": „" + String(last.prefix(160)) + "“")
    }
}
