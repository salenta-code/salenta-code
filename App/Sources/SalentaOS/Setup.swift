import AgenticOSKit
import AppKit
import SwiftUI

// Einrichtung beim ersten Start + Einstellungen: Profil, Bereiche, Agent-Regeln, Verbindungen, Mail-Signaturen.
// Alles bleibt lokal: data/areas.json im Projektordner, der Rest in den Einstellungen der App.

// MARK: - Bereiche

final class AreaStore: ObservableObject {
    static let shared = AreaStore()
    @Published var areas: [AreaDef] = AreaRegistry.fallback

    private var url: URL { Paths.data.appendingPathComponent("areas.json") }

    /// Beim Start aufrufen, bevor Aufgaben geladen werden.
    static func bootstrap() { shared.load() }

    func load() {
        if let d = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([AreaDef].self, from: d), !list.isEmpty {
            areas = list
        } else {
            areas = AreaRegistry.fallback
        }
        ensurePrivat()
        AreaRegistry.areas = areas
    }

    func save() {
        ensurePrivat()
        AreaRegistry.areas = areas
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try? enc.encode(areas).write(to: url, options: .atomic)
    }

    func add(title: String) {
        let base = title.lowercased().folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        var id = base.isEmpty ? "bereich" : base
        var n = 2
        while areas.contains(where: { $0.id == id }) { id = "\(base)-\(n)"; n += 1 }
        let palette: [UInt32] = [0x0A84FF, 0x30B15C, 0xF59E0B, 0xE8445A, 0x5A45FF, 0x2E7D6B, 0xC8102E, 0x8E5CF7]
        areas.append(AreaDef(id: id, title: title, hex: palette[areas.count % palette.count], symbol: "folder", tags: [id]))
        save()
    }

    private func ensurePrivat() {
        if !areas.contains(where: { $0.id == "privat" }) { areas.insert(AreaRegistry.fallback[0], at: 0) }
    }

    static let symbols = ["folder", "person", "briefcase", "building.2", "cart", "bag", "shield.lefthalf.filled", "tshirt",
                          "birthday.cake", "video", "waveform.path.ecg", "graduationcap", "house", "heart", "hammer",
                          "chart.bar", "globe", "paintbrush", "music.note", "airplane", "leaf", "car", "book", "star"]
}

// MARK: - Was ist auf diesem Mac vorhanden?

struct DetectedTool: Identifiable {
    var id: String { name }
    let name: String
    let detail: String
    let found: Bool
    let hint: String
}

enum Detection {
    private static var cache: [String: String?] = [:]
    private static let cacheLock = NSLock()

    /// Sucht ein Programm wie die Login-Shell (Homebrew, nvm, volta, bun …). Ergebnis wird gemerkt.
    static func which(_ tool: String) -> String? {
        cacheLock.lock(); let hit = cache[tool]; cacheLock.unlock()
        if let hit { return hit }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // -i: PATH aus .zshrc (dort tragen viele Installer claude, codex, npm-Globals ein)
        p.arguments = ["-l", "-i", "-c", "command -v \(tool)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        var result: String?
        if (try? p.run()) != nil {
            let deadline = Date().addingTimeInterval(5)
            while p.isRunning && Date() < deadline { usleep(20_000) }
            if p.isRunning { p.terminate() }
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { $0.hasPrefix("/") }
        }
        cacheLock.lock(); cache[tool] = result; cacheLock.unlock()
        return result
    }

    /// Befehl sichtbar im Terminal ausführen (Installation, Login) – du siehst alles und kannst eingreifen.
    static func runInTerminal(_ command: String) {
        let esc = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(esc)\"\nend tell"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    static func tools(system: SystemStatus) -> [DetectedTool] {
        func app(_ bundle: String) -> Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil }
        var out: [DetectedTool] = []
        for k in AgentKind.allCases where k != .shell {
            out.append(DetectedTool(name: k.title, detail: system.cliPaths[k] ?? "", found: system.installed(k),
                                    hint: k.installHint))
        }
        let tmux = which("tmux")
        out.append(DetectedTool(name: L("tmux (Sitzungen laufen weiter, wenn die App zu ist)"), detail: tmux ?? "", found: tmux != nil, hint: "brew install tmux"))
        out.append(DetectedTool(name: L("Whisper (beste Spracheingabe)"), detail: Dictation.whisperReady ? Dictation.whisperModel.lastPathComponent : "",
                                found: Dictation.whisperReady, hint: L("Einstellungen › Allgemein › Spracheingabe")))
        let gh = which("gh")
        out.append(DetectedTool(name: "GitHub CLI", detail: gh ?? "", found: gh != nil, hint: "brew install gh && gh auth login"))
        let npx = which("npx")
        out.append(DetectedTool(name: "Node.js (für den Browser des Agents)", detail: npx ?? "", found: npx != nil, hint: "brew install node"))
        out.append(DetectedTool(name: "Google Chrome", detail: "", found: app("com.google.Chrome"), hint: "google.com/chrome"))
        let vault = Obsidian.vault
        out.append(DetectedTool(name: "Obsidian-Vault", detail: vault?.path ?? "", found: vault != nil, hint: L("Optional – obsidian.md")))
        return out
    }
}

// MARK: - Einrichtung (erster Start)

struct SetupView: View {
    @EnvironmentObject private var system: SystemStatus
    @EnvironmentObject private var hub: MCPHub
    @EnvironmentObject private var calendar: CalendarService
    @EnvironmentObject private var mail: MailService
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var areas = AreaStore.shared
    @AppStorage("user.name") private var name = ""
    @AppStorage("user.language") private var language = ""
    @AppStorage("setup.done") private var done = false
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var newArea = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Grid.s) {
                ForEach(0..<5) { i in
                    Capsule().fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.25)).frame(height: 4)
                }
            }
            .padding(Grid.l)
            Group {
                switch step {
                case 0: welcome
                case 1: toolsStep
                case 2: ExtensionsSetupStep()
                case 3: areasStep
                default: connectStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, Grid.xl)
            Divider()
            HStack {
                if step > 0 { Button("Zurück") { step -= 1 } }
                Spacer()
                Button("Später") { finish() }.buttonStyle(.link)
                Button(step == 4 ? "Fertig" : "Weiter") { step == 4 ? finish() : (step += 1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Grid.l)
        }
        .frame(width: 640, height: 560)
        .onAppear {
            system.checkCLIs()
            if name.isEmpty { name = Profile.name == "du" ? "" : Profile.name }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Grid.l) {
            HStack(spacing: Grid.m) {
                Image(systemName: "sparkle").font(.system(size: 34)).foregroundStyle(.orange)
                Text("Willkommen bei Salenta Code").font(.system(size: 28, weight: .regular, design: .serif))
            }
            Text("Ein Fenster für alle deine KI-Agents: Claude Code, Codex, Junie und dein eigener Agent – mit deinen Tools, Aufgaben, Terminen und Mails. Du schreibst, was erledigt werden soll, Salenta Code sucht den passenden Agent aus.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Wie sollen dich die Agents nennen?", text: $name)
                Picker("Sprache der Agents", selection: $language) {
                    Text("Wie der Mac").tag("")
                    Text("Deutsch").tag("de")
                    Text("English").tag("en")
                }
            }
            .formStyle(.grouped)
            Label("Alles bleibt auf deinem Mac. Die Agents laufen über deine eigenen Abos (Claude, ChatGPT/Codex, JetBrains) – Salenta Code selbst braucht keinen API-Key.", systemImage: "lock")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var toolsStep: some View {
        VStack(alignment: .leading, spacing: Grid.m) {
            EssentialsView()
            Divider()
            Text("Gefunden auf deinem Mac").font(.title2.weight(.semibold))
            Text("Salenta Code nutzt, was du schon installiert hast. Du brauchst mindestens Claude Code – alles andere ist optional und lässt sich hier oder später mit einem Klick nachinstallieren (öffnet das Terminal, du siehst jeden Schritt).")
                .foregroundStyle(.secondary)
            HStack {
                Button("Erneut prüfen") { system.checkCLIs(); Persist.recheck() }
                Text("Tipp: Junie (Fehlersuche) und Codex (zweite Meinung) machen die automatische Prüfung besser.").font(.caption).foregroundStyle(.tertiary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Grid.s) {
                    ForEach(Detection.tools(system: system)) { t in
                        HStack(alignment: .top, spacing: Grid.m) {
                            Image(systemName: t.found ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundStyle(t.found ? Color.green : Color.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.name).font(.callout.weight(.medium))
                                Text(t.found ? t.detail : t.hint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            if !t.found, t.hint.contains("|") || t.hint.hasPrefix("npm ") || t.hint.hasPrefix("brew ") || t.hint.hasPrefix("curl ") {
                                Button("Installieren") { Detection.runInTerminal(t.hint) }.controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
    }

    private var areasStep: some View {
        VStack(alignment: .leading, spacing: Grid.m) {
            Text("Deine Bereiche").font(.title2.weight(.semibold))
            Text("Bereiche ordnen Aufgaben und Aufträge, z. B. deine Firmen, Projekte oder Kunden. Salenta Code erkennt sie auch an Repo-Namen und Stichwörtern.")
                .foregroundStyle(.secondary)
            List {
                ForEach($areas.areas) { $a in
                    HStack(spacing: Grid.s) {
                        Circle().fill(Color(hex: a.hex)).frame(width: 10, height: 10)
                        TextField("Name", text: $a.title)
                        if a.id != "privat" {
                            Button { areas.areas.removeAll { $0.id == a.id }; areas.save() } label: { Image(systemName: "minus.circle") }.help(L("Bereich entfernen"))
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .frame(minHeight: 160)
            HStack {
                TextField("Neuer Bereich, z. B. Meine Firma", text: $newArea).onSubmit(addArea)
                Button("Hinzufügen", action: addArea).disabled(newArea.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onDisappear { areas.save() }
    }

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: Grid.m) {
            Text("Verbinden").font(.title2.weight(.semibold))
            let byOrigin = Dictionary(grouping: hub.all, by: \.origin)
            Text(hub.all.isEmpty
                 ? "Noch keine MCP-Server gefunden. Du kannst jederzeit welche hinzufügen."
                 : "\(hub.all.count) MCP-Server gefunden – aus \(byOrigin.keys.sorted().joined(separator: ", ")). Sie stehen allen Agents zur Verfügung.")
                .foregroundStyle(.secondary)
            Form {
                LabeledContent("Kalender") {
                    Button(calendar.access == .granted ? "Verbunden" : "Erlauben") { calendar.requestAccess() }
                        .disabled(calendar.access == .granted)
                }
                LabeledContent("Apple Mail") {
                    Button("Erlauben") { mail.reload() }
                }
                LabeledContent("MCP-Server & Apps") {
                    Button("Integrationen öffnen") { finish(); app.page = .mcp }
                }
                LabeledContent("Web-Apps") {
                    Text("In der Seitenleiste unter Apps › „App hinzufügen“").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }

    private func addArea() {
        let t = newArea.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        areas.add(title: t)
        newArea = ""
    }

    private func finish() {
        areas.save()
        done = true
        dismiss()
    }
}

// MARK: - Einstellungen

struct ProfileSettings: View {
    @AppStorage("user.name") private var name = ""
    @AppStorage("user.language") private var language = ""
    @AppStorage("agent.rules") private var rules = ""
    @AppStorage("setup.done") private var done = true

    var body: some View {
        Form {
            Section("Du") {
                TextField("Name", text: $name, prompt: Text(Profile.name))
                Picker("Sprache der Agents", selection: $language) {
                    Text("Wie der Mac").tag("")
                    Text("Deutsch").tag("de")
                    Text("English").tag("en")
                }
            }
            Section("Deine Regeln für alle Agents") {
                TextEditor(text: $rules)
                    .font(.body)
                    .frame(minHeight: 160)
                Text("Eine Regel pro Zeile, z. B. „Kundenmails immer mit Impressum“ oder „Nie direkt auf main pushen“. Gilt für deinen OS-Agent bei jedem Auftrag.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Einrichtung erneut starten") { done = false }
            }
        }
        .formStyle(.grouped)
    }
}

struct AreaSettings: View {
    @ObservedObject private var store = AreaStore.shared
    @State private var newArea = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.m) {
            Text("Bereiche ordnen Aufgaben und Aufträge. Kürzel nutzt du beim Notieren (#kürzel), Stichwörter erkennen Repos und Texte.")
                .foregroundStyle(.secondary)
            List {
                ForEach($store.areas) { $a in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: Grid.s) {
                            ColorPicker("", selection: Binding(get: { Color(hex: a.hex) }, set: { a.hex = $0.hexValue }))
                                .labelsHidden().frame(width: 30)
                            Picker("", selection: $a.symbol) {
                                ForEach(AreaStore.symbols, id: \.self) { s in Image(systemName: s).tag(s) }
                            }
                            .labelsHidden().frame(width: 60)
                            TextField("Name", text: $a.title)
                            if a.id != "privat" {
                                Button { store.areas.removeAll { $0.id == a.id }; store.save() } label: { Image(systemName: "trash") }.help(L("Bereich löschen"))
                                    .buttonStyle(.borderless)
                            }
                        }
                        HStack {
                            TextField("Kürzel (Komma)", text: Binding(get: { a.tags.joined(separator: ", ") },
                                                                     set: { a.tags = Self.split($0) }))
                            TextField("Stichwörter / Repo-Namen (Komma)", text: Binding(get: { a.keywords.joined(separator: ", ") },
                                                                                        set: { a.keywords = Self.split($0) }))
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 4)
                }
            }
            HStack {
                TextField("Neuer Bereich", text: $newArea).onSubmit(add)
                Button("Hinzufügen", action: add)
                Spacer()
                Button("Sichern") { store.save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Grid.l)
        .onDisappear { store.save() }
    }

    private func add() {
        let t = newArea.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        store.add(title: t)
        newArea = ""
    }

    static func split(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }
}

struct MailSettings: View {
    @EnvironmentObject private var mail: MailService
    @State private var signatures: [String: String] = UserDefaults.standard.dictionary(forKey: "mail.signatures") as? [String: String] ?? [:]
    @StateObject private var client = MailClient()

    @AppStorage("mail.blockRemote") private var blockRemote = false

    var body: some View {
        Form {
            Section("Anzeige") {
                Toggle("Bilder aus dem Internet blockieren (Schutz vor Tracking-Pixeln)", isOn: $blockRemote)
                Text("Eingebettete Bilder und Anhänge werden immer angezeigt. Externe Bilder kannst du pro Mail mit „Laden“ freigeben.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Signatur pro Konto") {
                if client.accounts.isEmpty { Text("Keine Konten aus Apple Mail gefunden.").foregroundStyle(.secondary) }
                ForEach(client.accounts) { a in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(a.name).font(.callout.weight(.medium))
                        TextEditor(text: Binding(get: { signatures[a.name] ?? "" }, set: {
                            signatures[a.name] = $0
                            UserDefaults.standard.set(signatures, forKey: "mail.signatures")
                        }))
                        .frame(minHeight: 60)
                        .font(.callout)
                    }
                }
                Text("Wird beim Senden aus Salenta Code angehängt, z. B. mit Pflichtangaben oder Impressum.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { client.reload() }
    }
}

struct ConnectionSettings: View {
    @EnvironmentObject private var system: SystemStatus
    @EnvironmentObject private var hub: MCPHub
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Form {
            Section("Agents und Werkzeuge auf diesem Mac") {
                ForEach(Detection.tools(system: system)) { t in
                    HStack {
                        Image(systemName: t.found ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(t.found ? Color.green : Color.secondary)
                        Text(t.name)
                        Spacer()
                        Text(t.found ? t.detail : t.hint).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        if !t.found, t.hint.contains("|") || t.hint.hasPrefix("npm ") || t.hint.hasPrefix("brew ") || t.hint.hasPrefix("curl ") {
                            Button("Installieren") { Detection.runInTerminal(t.hint) }.controlSize(.small)
                        }
                    }
                }
                Button("Erneut prüfen") { system.checkCLIs() }
            }
            Section("MCP-Server") {
                let groups = Dictionary(grouping: hub.all, by: \.origin)
                ForEach(groups.keys.sorted(), id: \.self) { o in
                    LabeledContent(o, value: "\(groups[o]?.count ?? 0)")
                }
                Text("Salenta Code übernimmt automatisch alle MCP-Server aus Claude Code, Claude Desktop, Codex, Cursor und Junie. Eigene fügst du unter Integrationen hinzu.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Integrationen öffnen") {
                    app.page = .mcp
                    AppDelegate.showMainWindow()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { system.checkCLIs() }
    }
}

extension Color {
    /// 0xRRGGBB aus einer SwiftUI-Farbe.
    var hexValue: UInt32 {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return (UInt32(c.redComponent * 255) << 16) | (UInt32(c.greenComponent * 255) << 8) | UInt32(c.blueComponent * 255)
    }
}
