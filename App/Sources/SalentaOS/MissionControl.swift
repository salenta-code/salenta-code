import AgenticOSKit
import AppKit
import UniformTypeIdentifiers
import SwiftUI

// Mission Control: ein Eingabefeld für Aufträge an jede KI, und ein Board,
// das zeigt, was gerade bei welchem Anbieter läuft.

/// Wohin ein Auftrag geht.
enum MissionTarget: String, CaseIterable, Identifiable {
    case auto, osAgent, claude, codex, junie, cursor, opencode, gemini, grok, kiro, pi, kimi, openrouter, ollama, chatgpt, claudeWeb

    /// Ziel für einen Terminal-Agent.
    static func from(_ k: AgentKind) -> MissionTarget {
        switch k {
        case .claude: .claude
        case .codex: .codex
        case .junie: .junie
        case .cursor: .cursor
        case .opencode: .opencode
        case .gemini: .gemini
        case .grok: .grok
        case .kiro: .kiro
        case .pi: .pi
        case .kimi: .kimi
        case .openrouter: .openrouter
        case .ollama: .ollama
        case .shell: .claude
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: L("Automatisch")
        case .osAgent: L("OS-Agent")
        case .claude: L("Claude Code")
        case .codex: L("Codex")
        case .junie: L("Junie")
        case .cursor: "Cursor"
        case .opencode: "OpenCode"
        case .gemini: "Gemini CLI"
        case .grok: "Grok Build"
        case .kiro: "Kiro"
        case .pi: "Pi"
        case .kimi: "Kimi Code"
        case .openrouter: L("Open-Source-Modelle (OpenRouter)")
        case .ollama: L("Lokal (Ollama)")
        case .chatgpt: L("ChatGPT")
        case .claudeWeb: L("Claude (Web)")
        }
    }

    var symbol: String {
        switch self {
        case .auto: "wand.and.sparkles"
        case .osAgent: "sparkles"
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .junie: "j.square"
        case .cursor, .opencode, .gemini, .grok, .kiro, .pi, .kimi, .openrouter, .ollama: agent?.symbol ?? "terminal"
        case .chatgpt: "bubble.left.and.bubble.right"
        case .claudeWeb: "globe"
        }
    }

    var hint: String {
        switch self {
        case .auto: L("Salenta Code entscheidet: Coding → Claude Code im Projekt, alles andere → dein Agent")
        case .osAgent: L("Dein Agent im Salenta Code – nutzt alle verbundenen Tools, Obsidian und den Browser, fragt vor dem Senden")
        case .claude: L("Coding, Dateien, Features – arbeitet im gewählten Ordner")
        case .codex: L("Coding mit OpenAI Codex im gewählten Ordner")
        case .junie: L("JetBrains Junie – Fehler finden und beheben, auch die von anderen Agents")
        case .cursor: L("Cursor-Agent im gewählten Ordner – schnelle Änderungen, gut für Frontend")
        case .opencode: L("OpenCode – Open-Source-Agent mit beliebigem Modell-Anbieter")
        case .gemini: L("Google Gemini CLI – riesiger Kontext, große Codebasen")
        case .grok: L("xAI Grok Build – schnelle Umsetzung, parallele Agents")
        case .kiro: L("AWS Kiro – spec-getriebene Entwicklung, AWS")
        case .pi: L("Pi – minimaler Coding-Agent für kleine, klare Aufgaben")
        case .kimi: L("Kimi Code von Moonshot – starke, günstige Kimi-Modelle, lange Aufgaben, Frontend")
        case .openrouter: L("Claude Code mit Qwen, DeepSeek, Kimi, GLM … über OpenRouter – günstig, pro Nutzung bezahlt")
        case .ollama: L("Claude Code mit einem Open-Source-Modell lokal auf deinem Mac – kostenlos und privat")
        case .chatgpt: L("Öffnet ChatGPT und setzt den Auftrag ein")
        case .claudeWeb: L("Öffnet claude.ai und setzt den Auftrag ein")
        }
    }

    var agent: AgentKind? {
        switch self {
        case .osAgent, .claude: .claude
        case .codex: .codex
        case .junie: .junie
        case .cursor: .cursor
        case .opencode: .opencode
        case .gemini: .gemini
        case .grok: .grok
        case .kiro: .kiro
        case .pi: .pi
        case .kimi: .kimi
        case .openrouter: .openrouter
        case .ollama: .ollama
        case .auto, .chatgpt, .claudeWeb: nil
        }
    }

    var panelID: String? {
        switch self {
        case .chatgpt: "chatgpt"
        case .claudeWeb: "claude"
        default: nil
        }
    }

    /// Terminal-Agents kennen interaktiv und autonom.
    var hasModes: Bool { agent != nil && self != .osAgent }
}

extension Agents {
    /// Auftrag aus dem Mission-Eingabefeld.
    static func missionPrompt(_ text: String, task: TaskItem, mode: RunMode, coding: Bool = false) -> String {
        var lines = [text, "", "---", "Salenta Code · Aufgabe \(task.id) · Bereich \(task.company.title)"]
        if mode == .autonom {
            lines.append("Arbeite selbstständig bis zum Ergebnis. Schließe mit einer kurzen Zusammenfassung (3–5 Sätze), was du gemacht hast und was offen ist.")
        } else {
            lines.append("Wenn du fertig bist: \(Paths.root.path)/bin/aos done \(task.id) \"Zusammenfassung\"")
        }
        // Notizen-Kontext nur für den OS-Agent – Coding-Agents sollen sich auf den Code konzentrieren.
        if !coding, let ctx = Obsidian.promptContext { lines += ["", ctx] }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Eingabefeld

struct MissionComposer: View {
    enum Style { case card, claude }
    @EnvironmentObject private var hub: MCPHub
    var style: Style = .card
    var seed: Binding<String> = .constant("")
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var tasks: TaskStore
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var system: SystemStatus
    @EnvironmentObject private var projects: ProjectCatalog
    @EnvironmentObject private var skillCatalog: SkillCatalog
    @State private var dismissed: Set<String> = []
    @State private var routing = false

    @AppStorage("mission.target.v3") private var targetRaw = MissionTarget.auto.rawValue
    @AppStorage("mission.mode") private var modeRaw = RunMode.interaktiv.rawValue
    @AppStorage("mission.company") private var companyRaw = Company.privat.rawValue
    @State private var text = ""
    @State private var directory = ""
    @State private var skills: Set<String> = []
    @State private var showProjects = false
    @State private var showSkills = false
    @State private var attachments: [URL] = []
    /// Vorschlag der Agentenwahl – erst bestätigen, dann starten.
    @State private var proposal: AIRouteDecision?
    @State private var proposalBody = ""
    @AppStorage("router.confirm") private var confirmFirst = true
    @AppStorage("mission.planFirst") private var planFirst = false
    /// Fragen-Modus: der Agent liest und erklärt nur – er ändert keine Datei.
    @AppStorage("mission.ask") private var askMode = false
    /// Eingabe sieht wie eine Frage aus (Fragezeichen am Ende oder Fragewort vorn, kein Bau-Auftrag).
    private var looksLikeQuestion: Bool { Self.isQuestion(text) }
    /// „Bauen“ bewusst gewählt, obwohl der Text wie eine Frage aussieht.
    @State private var forceBuild = false
    private var asking: Bool { !forceBuild && (askMode || looksLikeQuestion) }

    static func isQuestion(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.count > 3 else { return false }
        let build = ["bau ", "baue", "implementier", "füg ", "füge", "hinzufügen", "ändere", "änder ", "erstelle", "schreib ", "fix ", "behebe",
                     "mach ", "mache", "lösch", "entfern", "refactor", "build ", "add ", "implement", "create ", "change ", "remove ", "make ", "write "]
        if build.contains(where: { t.hasPrefix($0) || t.contains(" " + $0) }) { return false }
        let words = ["warum", "wieso", "weshalb", "was ", "wie ", "wo ", "wann", "welche", "welcher", "welches", "wer ", "gibt es", "kann ", "können",
                     "ist ", "sind ", "erklär", "verstehe", "why", "what", "how ", "where", "which", "who ", "when ", "is ", "are ", "does ", "do ", "can ", "explain"]
        return t.hasSuffix("?") || words.contains(where: { t.hasPrefix($0) })
    }
    @AppStorage("mission.parallel") private var parallel = 1
    /// An wen geht der Auftrag? "auto" = Betreuer, wenn das Projekt einen hat · "none" = direkt an einen Agent · sonst Betreuer-ID
    @State private var stewardPick = "auto"
    @ObservedObject private var stewardStore = Steward.shared
    @AppStorage("local.only") private var localOnly = false
    @FocusState private var focused: Bool

    private var target: MissionTarget { MissionTarget(rawValue: targetRaw) ?? .claude }
    private var mode: RunMode { RunMode(rawValue: modeRaw) ?? .interaktiv }
    private var company: Company { Company(rawValue: companyRaw) ?? .privat }
    /// Nur das Projekt, das du gewählt hast – kein stilles „zuletzt benutzt“. Leer = noch keins gewählt.
    private var dir: String { directory }
    private var dirName: String { directory.isEmpty ? L("Projekt wählen") : (directory as NSString).lastPathComponent }
    /// Modell pro Agent – die Liste kommt von der jeweiligen CLI (bzw. deinen zuletzt genutzten Modellen).
    @ObservedObject private var catalog = ModelCatalog.shared
    @State private var modelTick = 0
    @AppStorage("mission.effort.codex") private var codexEffort = ""

    private var modelAgent: AgentKind? {
        let t = target == .auto ? decision.target : target
        return t == .osAgent ? .claude : t.agent
    }

    private var modelMenu: some View {
        let a = modelAgent
        let sel = a.map { ModelCatalog.selected(for: $0) } ?? ""
        _ = modelTick
        return Menu {
            if let a, ModelCatalog.supportsModel(a) {
                Button { ModelCatalog.select("", for: a); modelTick += 1 } label: {
                    Label(target == .auto ? L("Modell: Automatisch") : L("Modell: Standard von ") + a.title, systemImage: "wand.and.sparkles")
                }
                Divider()
                // Nur die aktuellen Modelle – alle anderen unter „Alle Modelle“
                let current = catalog.latest(for: a)
                ForEach(current) { o in modelButton(o, agent: a, selected: sel) }
                let total = catalog.options(for: a).count
                if total > current.count {
                    Menu(L("Alle Modelle") + " (\(total))") {
                        ForEach(catalog.grouped(for: a), id: \.0) { group, opts in
                            if group.isEmpty {
                                ForEach(opts) { o in modelButton(o, agent: a, selected: sel) }
                            } else {
                                Menu(group.capitalized) { ForEach(opts) { o in modelButton(o, agent: a, selected: sel) } }
                            }
                        }
                    }
                }
                if catalog.options(for: a).isEmpty {
                    Text(catalog.refreshing ? L("Lade Modelle …") : L("Keine Modell-Liste – eigenes Modell eingeben"))
                }
                if a == .codex {
                    Divider()
                    Picker(L("Denktiefe"), selection: $codexEffort) {
                        Text("Standard").tag("")
                        Text("niedrig").tag("low")
                        Text("mittel").tag("medium")
                        Text("hoch").tag("high")
                        Text("sehr hoch").tag("xhigh")
                    }
                }
                // Ein Wähler für Agent und Modell (wie bei T3 Code): ein Modell eines anderen Agents wählt diesen Agent gleich mit –
                // so passen Agent und Modell immer zusammen.
                let others = AgentKind.coders.filter { $0 != a && ModelCatalog.supportsModel($0) && (!system.cliChecked || system.installed($0)) && !AgentOff.isOff($0) }
                if !others.isEmpty {
                    Divider()
                    Section(L("Anderer Agent")) {
                        ForEach(others, id: \.self) { k in
                            Menu(k.title) {
                                Button(L("Standardmodell")) { targetRaw = MissionTarget.from(k).rawValue; ModelCatalog.select("", for: k); modelTick += 1 }
                                ForEach(catalog.latest(for: k, limit: 6)) { o in
                                    Button(o.hint.isEmpty ? o.label : "\(o.label) – \(o.hint)") {
                                        targetRaw = MissionTarget.from(k).rawValue; ModelCatalog.select(o.value, for: k); modelTick += 1
                                    }
                                }
                            }
                        }
                    }
                }
                Divider()
                Button(L("Eigenes Modell eingeben …")) {
                    if let v = ModelPrompt.ask(agent: a, current: sel) { ModelCatalog.select(v, for: a); modelTick += 1 }
                }
                Button(catalog.refreshing ? L("Aktualisiert …") : L("Modell-Listen neu laden")) { catalog.refresh() }
            } else {
                Text(L("Dieser Agent wählt sein Modell selbst"))
            }
        } label: {
            Text(modelLabel(a, sel)).font(.caption).foregroundStyle(sel.isEmpty ? .secondary : .primary)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(L("Modell für ") + (a?.title ?? "") + " – " + L("Liste kommt von der CLI"))
    }

    @ViewBuilder private func modelButton(_ o: ModelOption, agent: AgentKind, selected: String) -> some View {
        Button { ModelCatalog.select(o.value, for: agent); modelTick += 1 } label: {
            if o.value == selected { Label(o.hint.isEmpty ? o.label : "\(o.label) – \(o.hint)", systemImage: "checkmark") }
            else { Text(o.hint.isEmpty ? o.label : "\(o.label) – \(o.hint)") }
        }
    }

    private func modelLabel(_ a: AgentKind?, _ sel: String) -> String {
        var t = sel.isEmpty ? L("Modell: auto") : (sel.components(separatedBy: "/").last ?? sel)
        if ["opus", "sonnet", "haiku"].contains(t) { t = t.capitalized }
        if a == .codex, !codexEffort.isEmpty { t += " · " + codexEffort }
        return t
    }

    /// Agent, der den Auftrag bekäme (für passende Skills).
    private var effectiveAgent: AgentKind? {
        let t = target == .auto ? decision.target : target
        return t == .osAgent ? .claude : t.agent
    }

    /// Vorschläge: passende Skills und Projekte – annehmen mit Klick, wegklicken mit ×.
    @ViewBuilder private var suggestionRow: some View {
        let words = text.trimmingCharacters(in: .whitespaces)
        if words.count >= 12 {
            let sk = Router.suggestSkills(text, skills: skillCatalog.skills(for: effectiveAgent))
                .filter { !skills.contains($0.name) && !dismissed.contains("s:" + $0.name) }
            let usesFolder = (target == .auto ? decision.target : target).agent != nil && (target == .auto ? decision.target : target) != .osAgent
            let repos = usesFolder ? Router.candidates(for: text.lowercased(), projects: projects.local)
                .filter { $0.path != dir && $0.path != decision.directory && !dismissed.contains("p:" + $0.path) } : []
            if !sk.isEmpty || !repos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Vorschläge:").font(.caption).foregroundStyle(.secondary)
                        ForEach(sk.prefix(4)) { s in
                            SuggestChip(text: s.name, symbol: "wand.and.stars", help: s.description) {
                                skills.insert(s.name)
                            } dismiss: { dismissed.insert("s:" + s.name) }
                        }
                        ForEach(repos.prefix(3)) { p in
                            SuggestChip(text: p.name, symbol: "folder", help: p.path) {
                                directory = p.path
                            } dismiss: { dismissed.insert("p:" + p.path) }
                        }
                    }
                }
            }
        }
    }

    /// Zusätzliche Agents (Cursor, OpenCode, Gemini …) erscheinen nur, wenn sie installiert sind.
    private var visibleTargets: [MissionTarget] {
        let core: [AgentKind] = [.claude, .codex, .junie]
        return MissionTarget.allCases.filter { t in
            guard let a = t.agent else { return true }
            return core.contains(a) || (system.cliChecked && system.installed(a))
        }
    }

    private var decision: RouteDecision { Router.decide(text, projects: projects.local, recent: agents.directories) }

    var body: some View {
        Group {
            if style == .claude { claudeBody } else { cardBody }
        }
        .onChange(of: seed.wrappedValue) { _, v in if !v.isEmpty { text = v; seed.wrappedValue = ""; focused = true } }
        .onAppear(perform: takeDraft)
        .onChange(of: app.draft) { _, _ in takeDraft() }
    }

    /// Eingabe wie bei Claude: großes Feld, darunter Agent, Modus, Projekt, Skills und Senden.
    private var claudeBody: some View {
        VStack(alignment: .leading, spacing: Grid.s) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Was soll erledigt werden?")
                        .font(.title3).foregroundStyle(.tertiary)
                        .padding(.top, 8).padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.title3)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: 70, maxHeight: 220)
            }
            HStack(spacing: Grid.s) {
                Menu {
                    Button { showProjects = true } label: { Label(directory.isEmpty ? L("Projekt wählen …") : L("Projekt: ") + dirName, systemImage: "arrow.triangle.branch") }
                    Button { showSkills = true } label: { Label(skills.isEmpty ? "Skills wählen" : "\(skills.count) Skills", systemImage: "wand.and.stars") }
                    Divider()
                    Button { if let u = Attachments.fromPasteboard() { attachments.append(u) } else { app.show(L("Kein Bild in der Zwischenablage")) } } label: {
                        Label("Screenshot aus Zwischenablage", systemImage: "photo.on.rectangle")
                    }.keyboardShortcut("v", modifiers: [.command, .shift])
                    Button { attachments += Attachments.choose() } label: { Label("Dateien anhängen …", systemImage: "paperclip") }
                    Divider()
                    Toggle(isOn: $planFirst) { Label("Erst planen, dann umsetzen", systemImage: "list.bullet.clipboard") }
                    Picker(selection: $parallel) {
                        Text(L("Ein Agent")).tag(1)
                        Text(L("Team aus bis zu 2 Agents")).tag(2)
                        Text(L("Team aus bis zu 3 Agents")).tag(3)
                    } label: { Label(L("Team"), systemImage: "person.3") }
                    Picker("Bereich", selection: $companyRaw) {
                        ForEach(Company.allCases) { c in Text(c.title).tag(c.rawValue) }
                    }
                } label: { Image(systemName: "plus").font(.body.weight(.medium)) }.help(L("Hinzufügen: Dateien, Projekt, Skills und Optionen"))
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .popover(isPresented: $showProjects) { ProjectPicker(selection: Binding(get: { directory }, set: { directory = $0 })) }
                    .background(EmptyView().popover(isPresented: $showSkills) { SkillPicker(agent: target.agent, selected: $skills) })
                if !directory.isEmpty {
                    // gewähltes Projekt – mit × wieder lösen
                    HStack(spacing: 4) {
                        Button { showProjects = true } label: { Label(dirName, systemImage: "folder") }.buttonStyle(.plain)
                            .help(directory.replacingOccurrences(of: Paths.home.path, with: "~") + " – " + L("klicken zum Wechseln"))
                        Button { directory = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                            .help(L("Projekt lösen – dann wählt Salenta Code passend zum Auftrag"))
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.1)))
                } else if let a = target.agent, AgentKind.coders.contains(a) {
                    Button { showProjects = true } label: { Label(L("Projekt wählen"), systemImage: "folder.badge.plus") }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.orange)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().strokeBorder(Color.orange.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3])))
                }
                if !skills.isEmpty { Chip(text: "\(skills.count) Skills", symbol: "wand.and.stars") }
                if planFirst && !asking { Chip(text: L("erst Plan"), symbol: "list.bullet.clipboard") }
                // Bauen oder nur fragen – sichtbar umschaltbar; erkennt Fragen auch von selbst.
                Picker("", selection: Binding(get: { asking }, set: { if $0 { askMode = true; forceBuild = false } else { askMode = false; forceBuild = looksLikeQuestion } })) {
                    Label(L("Bauen"), systemImage: "hammer").tag(false)
                    Label(L("Fragen"), systemImage: "questionmark.bubble").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help(L("Fragen: Der Agent liest den Code und antwortet – er ändert nichts. Bauen: Er setzt den Auftrag um."))
                if asking {
                    Chip(text: looksLikeQuestion && !askMode ? L("Frage erkannt – ändert nichts") : L("Frage – ändert nichts"), symbol: "eye")
                        .help(L("Schreib einen Bau-Auftrag (z. B. „Bau …“), wenn er etwas ändern soll."))
                }
                if localOnly {
                    Chip(text: L("nur lokal"), symbol: "lock.laptopcomputer")
                        .help(L("Nur lokal ist an – alles läuft über das lokale Modell. Ändern: Menüleiste oder Einstellungen › Modelle"))
                }
                if parallel > 1 { Chip(text: L("Team") + " ≤ \(parallel)", symbol: "person.3") }
                if !stewardStore.projects.isEmpty {
                    Menu {
                        Picker("", selection: $stewardPick) {
                            Text(L("Automatisch (wenn das Projekt einen hat)")).tag("auto")
                            Text(L("Ohne Betreuer – direkt an einen Agent")).tag("none")
                            Divider()
                            ForEach(stewardStore.projects) { sp in Text(L("Betreuer") + " „" + sp.name + "“").tag(sp.id) }
                        }
                        .pickerStyle(.inline).labelsHidden()
                    } label: {
                        let name = stewardStore.project(stewardPick)?.name
                        Label(stewardPick == "none" ? L("Ohne Betreuer") : name.map { L("Betreuer") + ": " + $0 } ?? L("Betreuer: auto"), systemImage: "safari")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help(L("Wer den Auftrag bekommt: ein Projekt-Betreuer plant ihn als Team und betreut ihn bis zum fertigen Ergebnis"))
                }
                Spacer()
                if target.hasModes && target != .auto {
                    Menu {
                        Button { modeRaw = RunMode.autonom.rawValue } label: { Label("Selbstständig – arbeitet allein bis zum Ergebnis", systemImage: "bolt.fill") }
                        Button { modeRaw = RunMode.interaktiv.rawValue } label: { Label("Im Dialog – du sprichst mit dem Agent", systemImage: "bubble.left.and.text.bubble.right") }
                    } label: {
                        Text(mode == .autonom ? "Selbstständig" : "Im Dialog").font(.callout)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                Menu {
                    ForEach(visibleTargets) { t in
                        let available = t.agent.map { !system.cliChecked || system.installed($0) } ?? true
                        Button { targetRaw = t.rawValue } label: { Label("\(t.title) – \(t.hint)", systemImage: t.symbol) }
                            .disabled(!available)
                    }
                } label: {
                    if target == .auto && !text.trimmingCharacters(in: .whitespaces).isEmpty {
                        Label("→ \(decision.target.title)\(decision.projectName.map { " · \($0)" } ?? "")", systemImage: decision.target.symbol)
                            .font(.callout)
                    } else {
                        Label(target.title, systemImage: target.symbol).font(.callout)
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help(target == .auto ? decision.reason : target.hint)
                modelMenu
                MicButton { t in text += (text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n") ? "" : " ") + t; focused = true }
                Button { launch() } label: {
                    if routing {
                        ProgressView().controlSize(.small).frame(width: 30, height: 30)
                    } else {
                    Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary.opacity(0.4) : Color.orange))
                    }
                }
                .help(routing ? L("Wählt den besten Agent und das Modell …") : L("Starten (⌘↩)"))
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            DictationStrip()
            AttachmentChips(items: $attachments)
            if let p = proposal {
                ProposalCard(decision: Binding(get: { p }, set: { proposal = $0 }), visible: visibleTargets, projects: projects.local,
                             start: { d in dispatch(proposalBody, d) },
                             plain: {
                                 dispatch(proposalBody, AIRouteDecision(target: .claude, model: nil, effort: nil, directory: nil, skills: [],
                                                                       reason: L("Ohne Vorschläge – Claude Code im Dialog, wie gewohnt")), plain: true)
                             },
                             cancel: { withAnimation(.snappy) { proposal = nil } })
            } else {
                suggestionRow
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { attachments.append(url) } }
                }
            }
            return true
        }
        .padding(Grid.m)
        .background(ModernCardBackground(radius: 20))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
        .onAppear { focused = true }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: Grid.m) {
            HStack(spacing: Grid.s) {
                Image(systemName: "paperplane.fill").foregroundStyle(Color.accentColor)
                Text("Auftrag an KI").font(.headline)
                Spacer()
                Text(target.hint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            // Ziel wählen – umbrechend in ganzen Knöpfen (nie Text mitten im Knopf umbrechen)
            FlowLayout(spacing: Grid.xs) {
                ForEach(visibleTargets) { t in
                    let available = t.agent.map { !system.cliChecked || system.installed($0) } ?? true
                    Button {
                        targetRaw = t.rawValue
                    } label: {
                        Label(t.title, systemImage: t.symbol)
                            .font(.callout)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, Grid.s)
                            .padding(.vertical, 5)
                            .background(target == t ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.08),
                                        in: Capsule())
                            .overlay(Capsule().strokeBorder(target == t ? Color.accentColor : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .disabled(!available)
                    .opacity(available ? 1 : 0.4)
                    .help(available ? t.hint : t.title + " " + L("ist nicht installiert"))
                }
            }

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Was soll erledigt werden? z. B. „Finde heraus, warum der Login in meiner App fehlschlägt, und fixe es“")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: 64, maxHeight: 140)
            }
            .padding(Grid.xs)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))

            HStack(spacing: Grid.m) {
                if target.hasModes {
                    Picker("", selection: $modeRaw) {
                        ForEach(RunMode.allCases) { m in Label(m.title, systemImage: m.symbol).tag(m.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .help("Interaktiv: du sprichst mit dem Agent im Terminal. Autonom: er arbeitet allein und setzt die Aufgabe am Ende auf erledigt.")
                }
                if target.agent != nil {
                    Button { showProjects = true } label: {
                        Label(dirName, systemImage: "arrow.triangle.branch")
                    }
                    .help(directory.isEmpty ? L("Projekt wählen") : "Repo / Projekt: \(directory)")
                    .popover(isPresented: $showProjects) {
                        ProjectPicker(selection: Binding(get: { directory }, set: { directory = $0 }))
                    }
                    Button { showSkills = true } label: {
                        Label(skills.isEmpty ? "Skills" : "\(skills.count) Skill\(skills.count == 1 ? "" : "s")", systemImage: "wand.and.stars")
                    }
                    .help(skills.sorted().joined(separator: ", "))
                    .popover(isPresented: $showSkills) {
                        SkillPicker(agent: target.agent, selected: $skills)
                    }
                }
                Picker("Bereich", selection: $companyRaw) {
                    ForEach(Company.allCases) { c in Text(c.title).tag(c.rawValue) }
                }
                .fixedSize()
                Spacer()
                MicButton { t in text += (text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n") ? "" : " ") + t; focused = true }
                Button {
                    launch()
                } label: {
                    Label("Starten", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Grid.l)
        .background(ModernCardBackground(radius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(focused ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.25)))
    }

    /// Vorbelegung aus Mail oder Projekt-Cockpit übernehmen.
    private func takeDraft() {
        guard let d = app.draft else { return }
        text = d
        if let dir = app.draftDir { directory = dir }
        app.draft = nil
        app.draftDir = nil
        focused = true
    }

    /// Du hast ein Projekt gewählt (Projekt-Chip / „Weiterarbeiten“): dann arbeitet ein Coding-Agent genau dort –
    /// auch bei Fragen wie „wie weit bist du?“, denn die Antwort steht im Repo, nicht in Mail oder Kalender.
    private func pinProject(_ d: AIRouteDecision, text: String) -> AIRouteDecision {
        guard !directory.isEmpty else { return d }
        var x = d
        x.directory = directory
        if d.target == .osAgent || d.target == .auto {
            x.target = .claude
            x.model = AIRouter.defaultModel(for: .claude, text: text)
            x.reason = String(format: L("Im Projekt %@ – Claude Code arbeitet direkt im Repo"), (directory as NSString).lastPathComponent)
        }
        return x
    }

    private func launch() {
        if LocalFirst.shared.localOnlyBlocked {
            app.show(L("Nur lokal ist an, aber kein lokales Modell ist bereit – Einstellungen › Modelle › Lokal"))
            return
        }
        if let p = proposal { dispatch(proposalBody, p); return }   // ⌘↩ bestätigt den Vorschlag
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !routing else { return }
        // Ausdrücklich einem Betreuer zugewiesen: er übernimmt den Auftrag – plant das Team, setzt um, liefert
        if !asking, stewardPick != "auto", stewardPick != "none", Steward.shared.project(stewardPick) != nil {
            let full = body + Attachments.promptBlock(attachments)
            attachments = []
            let sid = Steward.shared.takeOrder(stewardPick, text: full, lead: target.agent, teamSize: parallel)
            text = ""
            stewardPick = "auto"
            app.page = .steward(sid)
            return
        }
        if target == .auto {
            let fallback = decision
            // Die KI-Agentenwahl fragt ein Cloud-Modell – bei „Nur lokal“ entscheidet die App selbst
            if AIRouter.enabled && LocalFirst.shared.isOnline && !LocalFirst.shared.localOnly {
                routing = true
                let installed = Set(AgentKind.allCases.filter { !system.cliChecked || system.installed($0) })
                AIRouter.decide(body, projects: projects.local, skills: skillCatalog.skills, installed: installed,
                                tools: OSAgent.toolNames(hub: hub), fallback: fallback) { d in
                    routing = false
                    propose(body, LocalFirst.shared.adjust(Usage.shared.adjust(pinProject(d, text: body), installed: installed), text: body))
                }
            } else {
                let installed = Set(AgentKind.allCases.filter { !system.cliChecked || system.installed($0) })
                let m = ExtensionStore.shared.matches(body)
                propose(body, LocalFirst.shared.adjust(Usage.shared.adjust(pinProject(AIRouteDecision(target: fallback.target, model: AIRouter.defaultModel(for: fallback.target, text: body),
                                               effort: nil, directory: fallback.directory, skills: [], reason: fallback.reason,
                                               extensions: m.use.map(\.id), suggest: m.suggest.prefix(2).map(\.id)), text: body), installed: installed), text: body))
            }
        } else {
            if let a = target.agent, (Usage.shared.blocked[a.rawValue] ?? .distantPast) > Date() {
                app.show("⚠︎ \(a.title) " + L("ist gerade im Limit – „Automatisch“ würde einen anderen Agent nehmen"))
            }
            dispatch(body, AIRouteDecision(target: target, model: nil, effort: nil, directory: nil, skills: [], reason: ""))
        }
    }

    /// Vorschlag zeigen (Agent, Modell, Skills, Erweiterungen) – oder direkt starten, wenn ausgeschaltet.
    private func propose(_ body: String, _ d: AIRouteDecision) {
        if confirmFirst {
            proposalBody = body
            withAnimation(.snappy) { proposal = d }
        } else {
            dispatch(body, d)
        }
    }

    /// Startet den Auftrag mit der (automatisch oder von dir) gewählten Kombination aus Agent, Modell, Projekt und Skills.
    private func dispatch(_ request: String, _ d: AIRouteDecision, plain: Bool = false) {
        proposal = nil
        var body = request
        var d = d
        // Frage zu einem Projekt: immer ein Coding-Agent, der nur liest (Claude Code, oder Codex wenn gewählt).
        let question = asking && !plain
        forceBuild = false
        let qDir = (d.directory?.isEmpty == false ? d.directory! : self.dir)
        if question, !qDir.isEmpty, d.target != .codex { d.target = .claude }
        let auto = self.target == .auto && !plain
        // Genutzte Erweiterungen in den Auftrag (nur Claude-basierte Agents kennen die Plugins)
        if let ext = d.extensions, !ext.isEmpty, d.target == .claude || d.target == .osAgent {
            let lines = ext.compactMap { ExtensionCatalog.find($0)?.usage }.filter { !$0.isEmpty }
            if !lines.isEmpty { body += "\n\n" + L("Nutze dafür:") + "\n" + lines.map { "- " + $0 }.joined(separator: "\n") }
        }
        let target = d.target
        var dir = self.dir
        if let p = d.directory, !p.isEmpty, directory.isEmpty || auto { dir = p }   // Vorschlag (auch im Vorschlag geändert)
        // Code-Agents brauchen ein Projekt – nie still im zuletzt benutzten Ordner arbeiten
        if dir.isEmpty, let a = target.agent, AgentKind.coders.contains(a) {
            app.show(L("Für diesen Auftrag bitte zuerst ein Projekt wählen"))
            proposal = nil
            showProjects = true
            return
        }
        let mode: RunMode = plain ? .interaktiv : (auto ? .autonom : self.mode)
        // Manuelle Modellwahl schlägt die automatische.
        var model = d.model
        var effort = d.effort
        // Deine Modellwahl pro Agent schlägt die automatische.
        // Gilt für jeden Agent – auch Claude Code, Codex & Co. (vorher nur für den OS-Agent).
        if let a = target == .osAgent ? AgentKind.claude : target.agent, !ModelCatalog.selected(for: a).isEmpty { model = ModelCatalog.selected(for: a) }
        if !codexEffort.isEmpty { effort = codexEffort }
        body += Attachments.promptBlock(attachments)
        attachments = []
        let skills = self.skills.union(d.skills)
        if !skills.isEmpty, target.agent != nil {
            body += "\n\nNutze dafür diese Skills: " + skills.sorted().map { target == .claude || target == .osAgent ? "/\($0)" : $0 }.joined(separator: ", ")
        }
        let reason = d.reason
        let firstLine = body.components(separatedBy: .newlines).first ?? body
        let title = firstLine.count > 90 ? String(firstLine.prefix(88)) + "…" : firstLine
        let comp = companyRaw == Company.privat.rawValue ? (Router.company(for: body) ?? company) : company
        var task = TaskItem(title: title, notes: body, company: comp, status: .warten,
                            agent: target.agent, source: "mission:\(target.rawValue)")
        tasks.add(task)
        text = ""
        directory = ""   // Projekt gilt pro Auftrag – der nächste startet wieder frei

        switch target {
        case .auto: break
        case .osAgent:
            let prompt = Agents.missionPrompt(body, task: task, mode: .autonom)
            let tools = d.tools
            OSAgent.start(prompt, agents: agents, hub: hub, taskID: task.id, label: title, model: model, tools: tools) { s in
                MissionStore.shared.setMeta(s.id.uuidString, manual: !auto, tools: tools)
                if !reason.isEmpty { MissionStore.shared.setReason(s.id.uuidString, reason + (tools.map { $0.isEmpty ? "" : " · Tools: " + $0.joined(separator: ", ") } ?? "")) }
                agents.selected = s.id
                app.page = .chat(s.id.uuidString)
            }
        case .claude, .codex, .junie, .cursor, .opencode, .gemini, .grok, .kiro, .pi, .kimi, .openrouter, .ollama:
            guard let primary = target.agent else { return }
            let coding = AgentKind.coders.contains(primary)
            let ask = question && coding
            let plan = planFirst && coding && !ask
            // Auftrag für ein Projekt: der Projekt-Betreuer übernimmt ihn – plant das Team (Haupt-Agent + Zuarbeiten,
            // jeder mit passenden Skills und Erweiterungen), setzt um, prüft, liefert und meldet ein fertiges Ergebnis.
            // Gibt es schon einen Betreuer für das Projekt, macht er es immer; mit „Team“ wird er bei Bedarf angelegt.
            let root = Git.root(of: dir) ?? dir
            let hasSteward = Steward.shared.project(root) != nil
            let toSteward = UserDefaults.standard.object(forKey: "mission.toSteward") as? Bool ?? true
            if stewardPick != "none", coding, !question, !(planFirst && coding), !dir.isEmpty, toSteward, Git.root(of: dir) != nil, hasSteward || parallel > 1 {
                let sid = Steward.shared.takeOrder(dir, text: body, lead: auto ? nil : primary, teamSize: parallel)
                app.page = .steward(sid)
                return
            }
            let runMode: RunMode = (ask || plan || (parallel > 1 && coding)) ? .autonom : mode
            // Erfolgskriterium aus der Agentenwahl: der Agent prüft sich daran, der Prüfer später auch
            if !ask, coding, let c = d.doneWhen, !body.contains(c) { body += "\n\n" + L("Fertig, wenn:") + " " + c }
            var prompt = Agents.missionPrompt(body, task: task, mode: runMode, coding: coding)
            if ask {
                prompt = L("Das ist eine FRAGE, kein Auftrag. Ändere keine Dateien und führe nichts aus, was etwas verändert. Lies und durchsuche den betroffenen Code, bis du die Frage sicher beantworten kannst. Antworte dann: zuerst die Antwort in 1–3 Sätzen, danach die Begründung mit Dateien und Zeilen (Datei:Zeile). Wenn sinnvoll, schlag am Ende kurz vor, was man ändern könnte – aber setze es nicht um. Rufe nicht ExitPlanMode auf.") + "\n\n" + prompt
            } else if plan {
                prompt = L("Erstelle zuerst NUR einen Plan und ändere noch keine Dateien: Ziel, betroffene Dateien, Schritte, Risiken, wie du es testest. Der Nutzer gibt den Plan danach frei.") + "\n\n" + prompt
            }
            // Parallel: dieselbe Aufgabe an mehrere Agents (jeder in seiner Arbeitskopie) – danach vergleichen und die beste nehmen.
            var kinds = [primary]
            if parallel > 1 && coding && !plan && !ask {
                let installed = Set(AgentKind.allCases.filter { system.cliChecked && system.installed($0) })
                for k in [primary] + Usage.alternatives(primary) where kinds.count < parallel && !kinds.contains(k)
                    && installed.contains(k) && !Usage.shared.isTight(k) && AgentKind.coders.contains(k) { kinds.append(k) }
            }
            let group = kinds.count > 1 ? UUID().uuidString : nil
            for (i, agent) in kinds.enumerated() {
                let tools = (agent == .claude && runMode == .autonom) ? (d.tools ?? []).filter { $0 != "browser" } : []
                let begin: (URL?) -> Void = { cfg in
                    let s = agents.start(agent, in: dir, prompt: prompt, taskID: i == 0 ? task.id : nil, mode: runMode,
                                         label: kinds.count > 1 ? "\(title) · \(agent.title)" : title,
                                         model: ModelCatalog.selected(for: agent).isEmpty ? (agent == .claude || agent == .ollama ? model : nil) : ModelCatalog.selected(for: agent),
                                         effort: (agent == .codex || agent == .claude) ? (effort ?? "medium") : nil,
                                         codingConfig: cfg, planOnly: plan || ask, question: ask)
                    if let cfg { try? FileManager.default.removeItem(at: cfg) }
                    MissionStore.shared.setMeta(s.id.uuidString, manual: !auto, tools: tools.isEmpty ? nil : tools)
                    if plan {
                        MissionStore.shared.setPlan(s.id.uuidString, group: nil)
                        // Recherche-Agent läuft parallel zum Plan: aktueller Stand, Trends, Empfehlungen zum Anhaken
                        if Research.enabled, i == 0 { Research.shared.start(s.id.uuidString, request: request, directory: dir) }
                    }
                    if let group { MissionStore.shared.setPlan(s.id.uuidString, group: group) }
                    let why = (i == 0 ? reason : L("Parallel-Lösung zum Vergleich")) + (plan ? " · " + L("erst Plan") : "") + (ask ? " · " + L("nur Frage, ändert nichts") : "")
                    if !why.isEmpty { MissionStore.shared.setReason(s.id.uuidString, why + (tools.isEmpty ? "" : " · Tools: " + tools.joined(separator: ", "))) }
                    if i == 0 {
                        agents.selected = s.id
                        app.page = .chat(s.id.uuidString)
                    }
                }
                if tools.isEmpty {
                    begin(nil)
                } else {
                    Task {
                        let cfg = await OSAgent.prepareConfig(hub: hub, only: tools, browser: false, source: "claude")
                        await MainActor.run { begin(cfg) }
                    }
                }
            }
        case .chatgpt, .claudeWeb:
            guard let panel = target.panelID else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body, forType: .string)
            let embedded = (UserDefaults.standard.string(forKey: "web.embedded") ?? "").split(separator: ",").contains(Substring(panel))
            if Chrome.preferred && !embedded {
                // In Chrome mit deinem Login: Auftrag direkt per Link vorbelegen.
                var c = URLComponents(string: target == .chatgpt ? "https://chatgpt.com/" : "https://claude.ai/new")!
                c.queryItems = [URLQueryItem(name: "q", value: body)]
                if let url = c.url { Chrome.open(url) }
                app.show("In Chrome geöffnet – Auftrag ist eingesetzt (auch in der Zwischenablage)")
            } else {
                app.page = .panel(panel)
                WebPool.shared.insertPrompt(body, panelID: panel)
                app.show("Auftrag eingesetzt (auch in der Zwischenablage) – Enter zum Senden")
            }
        }
    }
}

// MARK: - Externe Prozesse (Claude Code, Codex außerhalb der App)

struct ExternalRun: Identifiable, Hashable {
    var id: Int32 { pid }
    let pid: Int32
    let tool: String
    let elapsed: String
    let directory: String
    let command: String
}

final class ProcessScanner: ObservableObject {
    @Published var runs: [ExternalRun] = []
    private var timer: Timer?

    func start(excluding: @escaping () -> Set<Int32>) {
        scan(excluding())
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.scan(excluding()) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func scan(_ own: Set<Int32>) {
        guard Energy.due("externalRuns", every: 60) else { return }
        DispatchQueue.global(qos: .utility).async {
            let out = Self.exec("/bin/ps", ["-axo", "pid=,ppid=,etime=,args="])
            var found: [ExternalRun] = []
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
                guard parts.count == 4, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
                if own.contains(pid) || own.contains(ppid) { continue }
                let args = parts[3]
                guard let tool = Self.tool(for: args) else { continue }
                let cwd = Self.cwd(of: pid)
                found.append(ExternalRun(pid: pid, tool: tool, elapsed: parts[2], directory: cwd, command: String(args.prefix(140))))
            }
            DispatchQueue.main.async { self.runs = found }
        }
    }

    private static func tool(for args: String) -> String? {
        let first = args.split(separator: " ").first.map(String.init) ?? ""
        let base = (first as NSString).lastPathComponent
        if base == "claude" { return args.contains("Claude.app") ? "Claude Desktop" : "Claude Code" }
        if base == "codex" { return "Codex" }
        if base == "junie" { return "Junie" }
        // node/python-Starter
        if args.contains("@anthropic-ai/claude-code") { return "Claude Code" }
        if args.contains("@openai/codex") { return "Codex" }
        return nil
    }

    private static func cwd(of pid: Int32) -> String {
        let out = exec("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"])
        for line in out.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst()).replacingOccurrences(of: Paths.home.path, with: "~")
        }
        return ""
    }

    private static func exec(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        while p.isRunning { usleep(20_000) }  // kein waitUntilExit: das dreht den RunLoop und kann SwiftUI mitten im Zeichnen abstürzen lassen
        return String(decoding: data, as: UTF8.self)
    }
}

struct MissionView: View {
    @EnvironmentObject private var live: LiveMonitor
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var system: SystemStatus
    @StateObject private var processes = ProcessScanner()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Grid.xl) {
                MissionComposer()
                summary
                HStack(alignment: .top, spacing: Grid.m) {
                    providerColumn("Claude Code", symbol: "sparkle", kind: .claude)
                    providerColumn("Codex", symbol: "chevron.left.forwardslash.chevron.right", kind: .codex)
                    providerColumn("Junie", symbol: "j.square", kind: .junie)
                }
                liveCard
                externalCard
            }
            .padding(Grid.xl)
            .frame(maxWidth: 1400, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Läuft gerade")
        .navigationSubtitle("\(agents.runningCount) Agent\(agents.runningCount == 1 ? "" : "s") arbeiten gerade")
        .toolbar {
            ToolbarItem {
                Button { processes.stop(); let mgr = agents; processes.start { Set(mgr.sessions.compactMap(\.shellPID)) } } label: { Label("Aktualisieren", systemImage: "arrow.clockwise") }.help(L("Aktualisieren"))
            }
        }
        .onAppear {
            let mgr = agents
            processes.start { Set(mgr.sessions.compactMap(\.shellPID)) }
        }
        .onDisappear {
            processes.stop()
        }
    }

    private var summary: some View {
        let running = agents.sessions.filter(\.running)
        let done = agents.sessions.filter { !$0.running && $0.succeeded }.count
        let failed = agents.sessions.filter { !$0.running && !$0.succeeded }.count
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Grid.m), count: 3), spacing: Grid.m) {
            StatTile(value: "\(running.count)", label: L("Läuft in Salenta Code"), symbol: "play.circle.fill", tint: SC.live)
            StatTile(value: "\(processes.runs.count)", label: L("Außerhalb gestartet"), symbol: "macwindow.on.rectangle", tint: .accentColor)
            StatTile(value: "\(done) / \(failed)", label: L("Fertig / Fehler (heute)"), symbol: "checkmark.seal.fill", tint: failed > 0 ? SC.warn : .accentColor)
        }
    }

    private func providerColumn(_ title: String, symbol: String, kind: AgentKind) -> some View {
        let list = agents.sessions.filter { $0.kind == kind }.reversed()
        return Card(title: "\(title)  ·  \(list.filter(\.running).count) aktiv", symbol: symbol,
                    trailing: AnyView(Button { agents.start(kind); app.page = .agents } label: { Image(systemName: "plus") }.help(L("Neue Sitzung starten"))
                        .buttonStyle(.borderless)
                        .disabled(system.cliChecked && !system.installed(kind)))) {
            if list.isEmpty {
                Text("Nichts aktiv.").foregroundStyle(.tertiary)
            }
            ForEach(Array(list)) { s in RunCard(session: s) }
        }
        .frame(maxWidth: .infinity)
    }



    /// Claude-Code- und Codex-Sitzungen aus anderen Fenstern – live als Chat ansehen.
    private var liveCard: some View {
        Card(title: "Live in anderen Fenstern  ·  \(live.active.count)", symbol: "eye") {
            if live.active.isEmpty { Text("Gerade keine aktiven Claude-Code- oder Codex-Sitzungen außerhalb.").foregroundStyle(.tertiary) }
            ForEach(live.active, id: \.url.path) { f in
                Button { app.page = .live(f.url.path) } label: {
                    HStack(spacing: Grid.m) {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Image(systemName: f.agent.symbol)
                        Text(Transcript.title(of: f.url)).lineLimit(1)
                        Spacer()
                        Text(Transcript.cwd(of: f.url).map { ($0 as NSString).lastPathComponent } ?? "").font(.caption).foregroundStyle(.secondary)
                        Text("Live ansehen").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var externalCard: some View {
        Card(title: "Außerhalb gestartet  ·  \(processes.runs.count)", symbol: "macwindow.on.rectangle") {
            Text("Claude Code und Codex, die in anderen Terminals, Cursor oder Claude Desktop laufen.")
                .font(.caption).foregroundStyle(.secondary)
            if processes.runs.isEmpty {
                Text("Keine.").foregroundStyle(.tertiary)
            }
            ForEach(processes.runs) { r in
                HStack(spacing: Grid.m) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text(r.tool).font(.callout.weight(.semibold)).frame(width: 120, alignment: .leading)
                    Text(r.directory.isEmpty ? "–" : r.directory).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(r.elapsed).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text("PID \(r.pid)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
                .help(r.command)
            }
        }
    }
}

/// Karte für einen Agent-Lauf.
struct RunCard: View {
    @ObservedObject var session: AgentSession
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var agents: AgentManager

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.s) {
            HStack(alignment: .top, spacing: Grid.s) {
                statusIcon
                Text(session.label).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack(spacing: Grid.s) {
                Label(session.mode.title, systemImage: session.mode.symbol)
                Text("·")
                Text(session.directory.lastPathComponent)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(duration(until: session.endedAt ?? ctx.date)).monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if session.running { LivePreview(session: session, lines: 5) }
            HStack {
                Button("Öffnen") {
                    agents.selected = session.id
                    app.page = .agents
                }
                if session.running {
                    Button("Stoppen", role: .destructive) { session.terminate() }
                } else {
                    Button("Entfernen") { agents.close(session.id) }
                }
            }
            .controlSize(.small)
        }
        .padding(Grid.m)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }

    @ViewBuilder private var statusIcon: some View {
        if session.running {
            ProgressView().controlSize(.small)
        } else if session.succeeded {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.orange)
                .help("Exit-Code \(session.exitCode.map(String.init(describing:)) ?? "?")")
        }
    }

    private func duration(until end: Date) -> String {
        let s = Int(end.timeIntervalSince(session.startedAt))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}


struct Chip: View {
    let text: String
    let symbol: String
    var body: some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.secondary.opacity(0.1)))
    }
}


struct SuggestChip: View {
    let text: String
    let symbol: String
    var help: String = ""
    let accept: () -> Void
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            Button(action: accept) { Label(text, systemImage: symbol).font(.caption).lineLimit(1) }
                .buttonStyle(.plain)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }.help(L("Vorschlag ausblenden"))
                .buttonStyle(.plain).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .help(help.isEmpty ? "Übernehmen" : help)
    }
}
