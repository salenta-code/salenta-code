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
    var base: String? = nil            // Ziel-Branch des PRs
}

enum GH {
    private static var authCache: (ok: Bool, at: Date)?
    private static var checking = false
    private static let lock = NSLock()
    /// gh installiert und angemeldet? Nie blockierend: gemerkter Wert, im Hintergrund alle 10 min aufgefrischt.
    static var ready: Bool {
        lock.lock(); let c = authCache; let busy = checking; lock.unlock()
        if c == nil || Date().timeIntervalSince(c!.at) > 600, !busy {
            lock.lock(); checking = true; lock.unlock()
            DispatchQueue.global(qos: .utility).async {
                let ok = Detection.which("gh") != nil && Proc.zsh("gh auth status >/dev/null 2>&1", in: NSTemporaryDirectory(), timeout: 15).code == 0
                lock.lock(); authCache = (ok, Date()); checking = false; lock.unlock()
            }
        }
        return c?.ok ?? false
    }
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
    var viaPR: Bool { hasGitHub && (github ?? true) && GH.ready }
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
        guard let p = project(id), p.hasGitHub, (p.github ?? true) else { return }
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
            if pr.reviewedSha != pr.sha, pr.reviewing != true { review(id, pr); continue }
            decide(id, pr)
        }
    }

    // MARK: Review

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
            var diff = Git.run(["diff", "origin/\(base)...\(ref)"], in: id, timeout: 90).out
            if diff.isEmpty { diff = Proc.zsh("gh pr diff \(pr.number)", in: id, timeout: 90).out }
            diff = "FILES:\n" + String(stat.suffix(4000)) + "\n\nPATCH:\n" + diff
            let lang = Profile.languageCode == "de" ? "German (plain, short)" : "English"
            let prompt = """
            You are a strict senior reviewer for the repository at \(id). Project goal: \(goal.isEmpty ? "-" : goal)
            Pull request #\(pr.number) "\(pr.title)" by \(pr.author), CI: \(pr.ci), mergeable: \(pr.mergeable).
            Review the diff for: correctness and obvious bugs, security (secrets, injection, auth), data loss, breaking changes,
            missing tests for risky logic, and whether it does what the title says. Ignore style nitpicks.
            CI is checked separately – do NOT reject because CI is still running or red. If the diff is truncated, judge the visible part
            and do NOT reject only because of truncation. Reject ("ok": false) only for concrete problems you can point to (file:line).
            "ok": true only if it is safe to merge as is. "risk": low | medium | high.
            Answer ONLY with JSON in \(lang): {"ok":true,"risk":"low","summary":"one or two sentences","issues":["file:line – problem – fix"]}

            DIFF (may be truncated):
            \(String(diff.prefix(80_000)))
            """
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("aos-prreview-\(UUID().uuidString).md")
            try? prompt.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            var j: [String: Any]?
            for model in ["opus", "sonnet"] {
                let r = Proc.zsh("claude -p --model \(model) --output-format json --max-turns 3 --strict-mcp-config < \(Shell.quote(file.path))",
                                 in: NSTemporaryDirectory(), timeout: 420)
                if let res = Verifier.claudeResult(r.out), let a = res.firstIndex(of: "{"), let b = res.lastIndex(of: "}"), a < b,
                   let x = try? JSONSerialization.jsonObject(with: Data(res[a...b].utf8)) as? [String: Any] { j = x; break }
                if Verifier.claudeFailure(r.out, code: r.code) == L("Claude ist im Limit") { break }
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
        guard let p = project(id), pr.reviewedSha == pr.sha else { return }
        let allowed = p.mergesPRs && (pr.ours || p.mergeAll == true)
        if pr.reviewOK == true, pr.risk != "high", pr.ci == "green" || pr.ci == "none", pr.mergeable != "CONFLICTING", allowed, !p.paused {
            DispatchQueue.global(qos: .userInitiated).async {
                let (ok, msg) = GitSync.mergePR(repo: id, number: pr.number)
                DispatchQueue.main.async {
                    self.say(id, "system", (ok ? "🎉 " : "") + msg)
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
        if pr.ours, broken, pr.fixedSha != pr.sha, (pr.fixCount ?? 0) < 2, Energy.backgroundAgentsOK, !p.paused {
            setPR(id, pr.number) { $0.fixedSha = pr.sha; $0.fixCount = ($0.fixCount ?? 0) + 1 }
            let why = pr.mergeable == "CONFLICTING" ? L("Konflikt mit dem Haupt-Branch – neuesten Stand einarbeiten (rebase/merge) und Konflikte lösen.")
                : pr.ci == "red" ? L("Die CI auf GitHub ist rot. Lies die Logs mit `gh pr checks` und `gh run view --log-failed` und behebe die Ursache.")
                : L("Das Review hat Einwände:") + "\n" + (pr.issues ?? []).map { "- " + $0 }.joined(separator: "\n")
            update(id) { q in
                q.tasks.append(StewardTask(title: String(format: L("PR #%d nachbessern: "), pr.number) + pr.title, detail: why,
                                           state: q.trust == 0 ? .idea : .queued, source: "ci", priority: 1, ref: pr.url + "@" + pr.sha,
                                           pr: pr.number, prBranch: pr.branch))
            }
            say(id, "system", "🔧 " + String(format: L("PR #%d braucht eine Korrektur – Aufgabe eingereiht."), pr.number))
            dispatch(id)
        } else if pr.ours, broken, (pr.fixCount ?? 0) >= 2, pr.fixedSha != pr.sha {
            setPR(id, pr.number) { $0.fixedSha = pr.sha }
            say(id, "system", "✋ " + String(format: L("PR #%d ist nach 2 Korrekturen noch nicht grün – bitte selbst ansehen (Auf GitHub) oder über „Alle prüfen …“ entscheiden."), pr.number))
        } else if !pr.ours, pr.reviewOK != nil, !allowed, pr.reviewedSha == pr.sha, pr.summary != nil {
            // fremder PR: nur Bescheid sagen (einmal je Stand – über reviewedSha schon abgedeckt)
        }
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
