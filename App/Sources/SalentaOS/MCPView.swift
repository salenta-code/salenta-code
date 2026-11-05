import AgenticOSKit
import AppKit
import SwiftUI

/// MCP-Hub: Katalog, installierte Server, Tools direkt ausführen.
struct MCPHubView: View {
    @EnvironmentObject private var hub: MCPHub
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var app: AppModel
    @State private var selection: String?
    @State private var tab = 0
    @State private var search = ""
    @State private var showCustom = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Verbunden (\(hub.all.count))").tag(0)
                    Text("Katalog (\(hub.catalog.count))").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(Grid.s)
                List(selection: $selection) {
                    if tab == 0 {
                        // Überblick: was funktioniert, was braucht dich
                        let states = hub.all.map { hub.connections[$0.id]?.state }
                        HStack(spacing: Grid.m) {
                            overviewChip(states.filter { $0 == .connected }.count, L("verbunden"), .green)
                            overviewChip(states.filter { if case .failed? = $0 { return true }; return false }.count, L("Fehler"), .red)
                            overviewChip(states.filter { $0 == nil || $0 == .idle }.count, L("nicht aktiv"), .secondary)
                        }
                        .padding(.vertical, 4)
                        // nach Zweck geordnet statt nach Herkunft
                        ForEach(byPurpose, id: \.0) { purpose, list in
                            Section(purpose) {
                                ForEach(list) { s in ServerRow(spec: s, origins: hub.origins(of: s)).tag(s.id) }
                            }
                        }
                    } else {
                        ForEach(filteredCatalog) { e in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: Grid.xs) {
                                        Text(e.name).font(.callout.weight(.semibold))
                                        if e.featured == true { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                                    }
                                    Text(e.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                if hub.isInstalled(e.name) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            }
                            .tag("catalog:" + e.name)
                        }
                    }
                }
                .searchable(text: $search, placement: .sidebar, prompt: "Server suchen")
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)

            Group {
                if let sel = selection, sel.hasPrefix("catalog:"),
                   let e = hub.catalog.first(where: { "catalog:" + $0.name == sel }) {
                    CatalogDetail(entry: e)
                } else if let sel = selection, let s = hub.all.first(where: { $0.id == sel }) {
                    ServerDetail(connection: hub.connection(for: s))
                        .id(s.id)
                } else {
                    ContentUnavailableView {
                        Label("MCP-Hub", systemImage: "point.3.connected.trianglepath.dotted")
                    } description: {
                        Text("Links alle MCP-Server deiner Agents (Claude Code, Codex, Junie, Claude Desktop, Cursor) plus ein Katalog. Salenta Code verbindet sich selbst mit ihnen – du kannst jedes Tool direkt hier ausführen und neue Server mit einem Klick in alle Agents installieren.")
                    }
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("MCP-Hub")
        .toolbar {
            ToolbarItemGroup {
                Button { showCustom = true } label: { Label("Eigener Server", systemImage: "plus") }.help(L("Eigenen Server hinzufügen"))
                Button { hub.reloadImported() } label: { Label("Neu einlesen", systemImage: "arrow.clockwise") }.help(L("Neu einlesen"))
            }
        }
        .sheet(isPresented: $showCustom) { CustomServerSheet() }
    }

    private func overviewChip(_ n: Int, _ label: String, _ c: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text("\(n)").fontWeight(.semibold)
            Text(label).foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    /// Wofür ein Server da ist – aus Name, Adresse und Beschreibung.
    static func purpose(_ s: MCPServerSpec) -> String {
        let t = (s.name + " " + (s.url ?? "") + " " + (s.command ?? "") + " " + (s.description ?? "")).lowercased()
        func has(_ w: [String]) -> Bool { w.contains { t.contains($0) } }
        if s.origin == "Salenta OS" || has(["salenta"]) { return L("Salenta") }
        if has(["gmail", "mail", "slack", "whatsapp", "telegram", "teams", "discord", "resend", "twilio", "imessage"]) { return L("Kommunikation") }
        if has(["calendar", "kalender", "cal.com", "calendly", "wispr", "plaud", "meeting"]) { return L("Kalender & Meetings") }
        if has(["drive", "notion", "obsidian", "docs", "dropbox", "confluence", "memory", "mem", "knowledge", "wissen"]) { return L("Wissen & Dateien") }
        if has(["github", "gitlab", "vercel", "supabase", "sentry", "neon", "replit", "lovable", "linear", "jira", "docker", "browser", "playwright", "chrome", "computer", "repl", "context7", "serena"]) { return L("Entwicklung") }
        if has(["meta", "facebook", "ads", "buffer", "canva", "hubspot", "heygen", "instagram", "tiktok", "seo", "analytics"]) { return L("Marketing & Inhalte") }
        if has(["shopify", "stripe", "paypal", "invoice", "buchhaltung", "accounting", "amazon"]) { return L("Shop & Finanzen") }
        return L("Weitere")
    }

    private var byPurpose: [(String, [MCPServerSpec])] {
        let list = hub.all.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        let order = [L("Salenta"), L("Entwicklung"), L("Kommunikation"), L("Kalender & Meetings"), L("Wissen & Dateien"),
                     L("Marketing & Inhalte"), L("Shop & Finanzen"), L("Weitere")]
        let groups = Dictionary(grouping: list, by: Self.purpose)
        return order.compactMap { o in groups[o].map { (o, $0.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) } }
    }

    private var groupedServers: [(String, [MCPServerSpec])] {
        let list = hub.all.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        let order = ["Salenta OS", "Claude Code", "Codex", "Junie", "Claude Desktop", "Cursor"]
        return order.compactMap { o in
            let l = list.filter { $0.origin == o }.sorted { $0.name < $1.name }
            return l.isEmpty ? nil : (o, l)
        }
    }

    private var filteredCatalog: [CatalogEntry] {
        search.isEmpty ? hub.catalog : hub.catalog.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search)
        }
    }
}

struct ServerRow: View {
    let spec: MCPServerSpec
    var origins: [String] = []
    @EnvironmentObject private var hub: MCPHub

    var body: some View {
        let conn = hub.connections[spec.id]
        HStack(spacing: Grid.s) {
            Circle().fill(color(conn?.state)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.friendly(spec.name)).lineLimit(1)
                HStack(spacing: 4) {
                    // in welchen Agents der Server eingetragen ist
                    ForEach(origins.isEmpty ? [spec.origin] : origins, id: \.self) { o in
                        Text(o == "Salenta OS" ? "Salenta Code" : o)
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                }
            }
        }
        .help(spec.transportLabel + " · " + (URL(string: spec.url ?? "")?.host ?? spec.command ?? ""))
    }

    /// „claude_ai_Google_Drive“ → „Google Drive“
    static func friendly(_ n: String) -> String {
        var t = n
        for p in ["claude_ai_", "plugin:", "mcp-", "mcp_"] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)) }
        t = t.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    private func color(_ s: MCPConnection.State?) -> Color {
        switch s {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        default: .secondary.opacity(0.4)
        }
    }
}

struct CatalogDetail: View {
    let entry: CatalogEntry
    @EnvironmentObject private var hub: MCPHub
    @EnvironmentObject private var agents: AgentManager
    @EnvironmentObject private var app: AppModel
    @State private var targets: Set<MCPHub.Target> = [.claude, .codex]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Grid.l) {
                Text(entry.name).font(.largeTitle.weight(.bold))
                Text(entry.description).foregroundStyle(.secondary)
                LabeledContent("Verbindung", value: entry.url ?? ([entry.command ?? ""] + (entry.args ?? [])).joined(separator: " "))
                LabeledContent("Anmeldung", value: entry.auth == "oauth" ? "OAuth (Browser-Anmeldung)" : "keine")
                if let src = entry.source, let u = URL(string: src) { Link("Dokumentation", destination: u) }
                Divider()
                Text("Installieren").font(.headline)
                Text("Salenta Code verbindet sich selbst. Zusätzlich kannst du den Server in deine Agents eintragen – das läuft sichtbar im Terminal, falls ein Agent nachfragt.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    ForEach(MCPHub.Target.allCases) { t in
                        Toggle(t.title, isOn: Binding(get: { targets.contains(t) },
                                                      set: { on in if on { targets.insert(t) } else { targets.remove(t) } }))
                            .toggleStyle(.checkbox)
                    }
                }
                HStack {
                    Button {
                        install()
                    } label: { Label(hub.isInstalled(entry.name) ? "Erneut installieren" : "Installieren", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderedProminent)
                    if hub.isInstalled(entry.name) {
                        Label("In Salenta Code installiert", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }
            .padding(Grid.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func install() {
        let spec = entry.spec
        hub.add(spec)
        let conn = hub.connection(for: spec)
        Task { await conn.connect() }
        if !targets.isEmpty {
            let s = agents.start(.shell, in: Paths.root.path, label: "MCP \(entry.name) installieren")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                s.send(hub.installScript(spec, targets: targets) + "\n")
            }
            app.show("\(entry.name) wird in \(targets.map(\.title).sorted().joined(separator: ", ")) eingetragen")
        }
    }
}

struct CustomServerSheet: View {
    @EnvironmentObject private var hub: MCPHub
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var command = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.m) {
            Text("Eigenen MCP-Server hinzufügen").font(.headline)
            Form {
                TextField("Name", text: $name)
                TextField("URL (HTTP, z. B. https://example.com/mcp)", text: $url)
                TextField("oder Befehl (stdio, z. B. npx -y paket)", text: $command)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Hinzufügen") {
                    let parts = command.split(separator: " ").map(String.init)
                    hub.add(MCPServerSpec(name: name.trimmingCharacters(in: .whitespaces),
                                          url: url.isEmpty ? nil : url.trimmingCharacters(in: .whitespaces),
                                          command: parts.first, args: parts.count > 1 ? Array(parts.dropFirst()) : nil,
                                          description: nil, origin: "Salenta OS", auth: nil))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || (url.isEmpty && command.isEmpty))
            }
        }
        .padding(Grid.l)
        .frame(width: 520)
    }
}

/// Ein Server: verbinden, Tools durchsuchen, ausführen.
struct ServerDetail: View {
    @ObservedObject var connection: MCPConnection
    @EnvironmentObject private var hub: MCPHub
    @State private var toolSearch = ""
    @State private var selectedTool: MCPTool?

    private var failure: String? {
        if case let .failed(m) = connection.state { return m }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Grid.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.spec.name).font(.title2.weight(.semibold))
                    Text("\(connection.spec.origin == "Salenta OS" ? "Salenta Code" : connection.spec.origin) · \(connection.spec.transportLabel) · \(connection.spec.target)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                switch connection.state {
                case .connected:
                    Label("\(connection.tools.count) Tools", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Trennen") { connection.disconnect() }
                case .connecting:
                    ProgressView().controlSize(.small)
                default:
                    Button("Verbinden") { Task { await connection.connect() } }.buttonStyle(.borderedProminent)
                }
                if let url = connection.spec.url, OAuthManager.shared.hasToken(for: url) {
                    Button("Abmelden") {
                        OAuthManager.shared.signOut(url)
                        connection.disconnect()
                    }
                }
                if connection.spec.origin == "Salenta OS" {
                    Button(role: .destructive) { hub.remove(connection.spec.name) } label: { Image(systemName: "trash") }.help(L("Integration entfernen"))
                }
            }
            .padding(Grid.l)
            if let msg = failure {
                Text(msg).foregroundStyle(.red).font(.callout).padding(.horizontal, Grid.l).padding(.bottom, Grid.s)
            }
            Divider()
            if connection.state == .connected {
                HSplitView {
                    List(selection: Binding(get: { selectedTool?.name }, set: { n in selectedTool = connection.tools.first { $0.name == n } })) {
                        ForEach(connection.tools.filter { toolSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(toolSearch) || $0.description.localizedCaseInsensitiveContains(toolSearch) }) { t in
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(t.name).font(.callout.monospaced())
                                    if t.readOnly { Image(systemName: "eye").font(.caption2).foregroundStyle(.secondary) }
                                    if t.destructive { Image(systemName: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange) }
                                }
                                Text(t.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .tag(t.name)
                        }
                    }
                    .frame(minWidth: 230, idealWidth: 280)
                    .safeAreaInset(edge: .top) {
                        TextField("Tool suchen", text: $toolSearch).textFieldStyle(.roundedBorder).padding(Grid.s)
                    }
                    Group {
                        if let t = selectedTool {
                            ToolRunner(connection: connection, tool: t).id(t.name)
                        } else {
                            ContentUnavailableView("Tool wählen", systemImage: "wrench.and.screwdriver",
                                                   description: Text("Jedes Tool lässt sich hier mit Formular ausführen."))
                        }
                    }
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Spacer()
            }
        }
        .task {
            // Ohne Browser-Anmeldung still versuchen (z. B. gespeichertes Token).
            if connection.state == .idle { await connection.connect(interactiveAuth: false) }
        }
    }
}

/// Formular aus dem JSON-Schema eines Tools.
struct ToolRunner: View {
    @ObservedObject var connection: MCPConnection
    let tool: MCPTool
    var prefill: [String: String] = [:]
    var onDone: ((MCPResult) -> Void)? = nil

    @State private var values: [String: String] = [:]
    @State private var flags: [String: Bool] = [:]
    @State private var running = false
    @State private var result: MCPResult?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Grid.m) {
                Text(tool.title).font(.headline)
                Text(tool.description).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if tool.destructive {
                    Label("Dieses Tool ändert oder sendet etwas.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                }
                ForEach(tool.params) { p in field(p) }
                HStack {
                    Button {
                        run()
                    } label: { Label(running ? "Läuft …" : "Ausführen", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(running || tool.params.contains { $0.required && ($0.type != "boolean") && (values[$0.name] ?? "").isEmpty })
                    .keyboardShortcut(.return, modifiers: .command)
                    if running { ProgressView().controlSize(.small) }
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if let result { ResultView(result: result) }
            }
            .padding(Grid.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { for (k, v) in prefill { values[k] = v } }
    }

    @ViewBuilder private func field(_ p: MCPParam) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(p.name).font(.callout.monospaced())
                if p.required { Text("Pflicht").font(.caption2).foregroundStyle(.orange) }
                Text(p.type).font(.caption2).foregroundStyle(.tertiary)
            }
            switch p.type {
            case "boolean":
                Toggle(p.description.isEmpty ? p.name : p.description, isOn: Binding(get: { flags[p.name] ?? false }, set: { flags[p.name] = $0 }))
                    .toggleStyle(.checkbox)
            case "enum":
                Picker("", selection: Binding(get: { values[p.name] ?? "" }, set: { values[p.name] = $0 })) {
                    Text("–").tag("")
                    ForEach(p.enumValues, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            case "array", "object":
                TextEditor(text: Binding(get: { values[p.name] ?? "" }, set: { values[p.name] = $0 }))
                    .font(.callout.monospaced())
                    .frame(height: 60)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                Text(p.type == "array" ? "JSON-Liste, z. B. [\"a\", \"b\"] – oder kommagetrennt" : "JSON-Objekt").font(.caption2).foregroundStyle(.tertiary)
            default:
                if p.name.contains("text") || p.name.contains("body") || p.name.contains("nachricht") || p.name == "inhalt" {
                    TextEditor(text: Binding(get: { values[p.name] ?? "" }, set: { values[p.name] = $0 }))
                        .frame(height: 80)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                } else {
                    TextField("", text: Binding(get: { values[p.name] ?? "" }, set: { values[p.name] = $0 }))
                        .textFieldStyle(.roundedBorder)
                }
            }
            if !p.description.isEmpty && p.type != "boolean" {
                Text(p.description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func arguments() -> [String: Any] {
        var args: [String: Any] = [:]
        for p in tool.params {
            if p.type == "boolean" {
                if let f = flags[p.name] { args[p.name] = f }
                continue
            }
            let raw = (values[p.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            switch p.type {
            case "integer": args[p.name] = Int(raw) ?? raw
            case "number": args[p.name] = Double(raw.replacingOccurrences(of: ",", with: ".")) ?? raw
            case "array":
                if let d = raw.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) { args[p.name] = j }
                else { args[p.name] = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            case "object":
                if let d = raw.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) { args[p.name] = j }
            default: args[p.name] = raw
            }
        }
        return args
    }

    private func run() {
        running = true
        error = nil
        let args = arguments()
        Task {
            do {
                let r = try await connection.callTool(tool.name, arguments: args)
                await MainActor.run {
                    result = r
                    running = false
                    onDone?(r)
                }
            } catch {
                let m = error.localizedDescription
                await MainActor.run {
                    self.error = m
                    running = false
                }
            }
        }
    }
}

/// Zeigt ein Tool-Ergebnis: Markdown-Felder als Text, Listen als Zeilen, sonst JSON.
struct ResultView: View {
    let result: MCPResult
    @State private var raw = false

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.s) {
            HStack {
                Label(result.isError ? "Fehler" : "Ergebnis", systemImage: result.isError ? "xmark.octagon" : "checkmark.circle")
                    .foregroundStyle(result.isError ? Color.red : Color.green)
                Spacer()
                Toggle("Rohdaten", isOn: $raw).toggleStyle(.switch).controlSize(.mini)
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.text, forType: .string) } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }
            if raw || result.json == nil {
                Text(pretty).font(.callout.monospaced()).textSelection(.enabled)
            } else {
                JSONBlock(value: result.json!)
            }
        }
        .padding(Grid.m)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
    }

    private var pretty: String {
        guard let j = result.json, let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return result.text }
        return String(decoding: d, as: UTF8.self)
    }
}

/// Generische, lesbare Darstellung von JSON.
struct JSONBlock: View {
    let value: Any
    var depth = 0

    var body: some View {
        if let dict = value as? [String: Any] {
            VStack(alignment: .leading, spacing: Grid.s) {
                // Markdown-Felder (z. B. "lagebericht") zuerst und groß
                ForEach(markdownKeys(dict), id: \.self) { k in
                    MarkdownText(dict[k] as? String ?? "")
                }
                ForEach(otherKeys(dict), id: \.self) { k in
                    if let v = dict[k], !jsonIsEmpty(v) {
                        if jsonIsScalar(v) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(keyLabel(k)).font(.caption).foregroundStyle(.secondary).frame(minWidth: 110, alignment: .leading)
                                Text(jsonScalar(v)).font(.callout).textSelection(.enabled)
                            }
                        } else if depth < 3 {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(keyLabel(k)).font(.subheadline.weight(.semibold))
                                AnyView(JSONBlock(value: v, depth: depth + 1)).padding(.leading, Grid.s)
                            }
                        }
                    }
                }
            }
        } else if let arr = value as? [Any] {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(arr.prefix(100).enumerated()), id: \.offset) { _, item in
                    if let d = item as? [String: Any] {
                        RowSummary(dict: d)
                    } else {
                        Text("• " + jsonScalar(item)).font(.callout).textSelection(.enabled)
                    }
                }
                if arr.count > 100 { Text("… \(arr.count - 100) weitere").font(.caption).foregroundStyle(.secondary) }
            }
        } else {
            Text(jsonScalar(value)).font(.callout).textSelection(.enabled)
        }
    }

    private func markdownKeys(_ d: [String: Any]) -> [String] {
        d.keys.filter { k in (d[k] as? String).map { $0.contains("\n") && ($0.contains("#") || $0.contains("- ")) } ?? false }.sorted()
    }

    private func otherKeys(_ d: [String: Any]) -> [String] {
        let md = Set(markdownKeys(d))
        return d.keys.filter { !md.contains($0) }.sorted { a, b in
            let sa = jsonIsScalar(d[a] as Any), sb = jsonIsScalar(d[b] as Any)
            return sa != sb ? sa : a < b
        }
    }
}

struct RowSummary: View {
    let dict: [String: Any]

    private static let titleKeys = ["title", "titel", "name", "subject", "betreff", "kontakt", "contactName", "kontakt_name", "text", "nachricht"]

    var body: some View {
        let title = Self.titleKeys.lazy.compactMap { dict[$0] as? String }.first ?? (dict["id"].map { "\($0)" } ?? "Eintrag")
        let details = dict.keys.sorted().filter { k in !Self.titleKeys.contains(k) && jsonIsScalar(dict[k] as Any) && !jsonIsEmpty(dict[k] as Any) }
            .prefix(5).map { "\(keyLabel($0)): \(jsonScalar(dict[$0] as Any).prefix(60))" }
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout.weight(.medium)).textSelection(.enabled)
            if !details.isEmpty {
                Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
        }
        .padding(Grid.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }
}

struct MarkdownText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("#") {
                    Text(t.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)).font(.headline).padding(.top, 4)
                } else if !t.isEmpty {
                    Text(inline(t)).font(.callout).textSelection(.enabled)
                }
            }
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

func jsonIsScalar(_ v: Any) -> Bool { !(v is [Any]) && !(v is [String: Any]) }

func jsonIsEmpty(_ v: Any) -> Bool {
    if v is NSNull { return true }
    if let s = v as? String { return s.isEmpty }
    if let a = v as? [Any] { return a.isEmpty }
    if let d = v as? [String: Any] { return d.isEmpty }
    return false
}

func jsonScalar(_ v: Any) -> String {
    if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "ja" : "nein" }
    if let s = v as? String {
        if s.count >= 20, s.contains("T"), let d = parseISO(s) {
            return d.formatted(date: .abbreviated, time: .shortened)
        }
        return s
    }
    if v is NSNull { return "–" }
    return "\(v)"
}

func keyLabel(_ key: String) -> String {
    key.replacingOccurrences(of: "_", with: " ").capitalized
}

/// ISO-8601 mit und ohne Sekundenbruchteile (Supabase liefert Mikrosekunden).
func parseISO(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    // Mikrosekunden auf Millisekunden kürzen
    if let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
        let frac = s[s.index(after: dot)..<end].prefix(3)
        return f.date(from: String(s[..<dot]) + "." + frac + String(s[end...]))
    }
    return nil
}
