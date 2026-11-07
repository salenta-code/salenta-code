import AgenticOSKit
import SwiftUI

/// Hilfe: liest docs/HILFE.md (in der App mitgeliefert) – eine Quelle für App und GitHub.
/// Links die Kapitel, rechts der Text, oben eine Suche über alles.
struct HelpView: View {
    @State private var sections: [HelpSection] = []
    @State private var selected: String?
    @State private var search = ""

    var body: some View {
        HSplitView {
            List(selection: $selected) {
                ForEach(filtered) { s in
                    Label(s.title, systemImage: s.symbol).tag(s.id)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 200, idealWidth: 230, maxWidth: 300)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Grid.xl) {
                        ForEach(filtered) { s in
                            VStack(alignment: .leading, spacing: Grid.m) {
                                Label(s.title, systemImage: s.symbol).font(.title2.weight(.semibold))
                                ForEach(Array(s.blocks.enumerated()), id: \.offset) { _, b in block(b) }
                            }
                            .id(s.id)
                            .frame(maxWidth: 760, alignment: .leading)
                        }
                        if filtered.isEmpty {
                            ContentUnavailableView.search(text: search)
                        }
                    }
                    .padding(Grid.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: selected) { _, id in
                    if let id { withAnimation(.snappy) { proxy.scrollTo(id, anchor: .top) } }
                }
            }
        }
        .navigationTitle(L("Hilfe"))
        .navigationSubtitle(L("So nutzt du Salenta Code"))
        .searchable(text: $search, placement: .toolbar, prompt: L("Hilfe durchsuchen"))
        .toolbar {
            ToolbarItem {
                Button { if let u = URL(string: "https://github.com/\(Updater.repo.isEmpty ? "salenta-code/salenta-code" : Updater.repo)/issues") { NSWorkspace.shared.open(u) } } label: {
                    Label(L("Fehler melden"), systemImage: "ladybug")
                }
                .help(L("Fehler melden oder Idee vorschlagen (GitHub)"))
            }
        }
        .task { if sections.isEmpty { sections = HelpSection.load() } }
    }

    private var filtered: [HelpSection] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return sections }
        return sections.filter { $0.title.lowercased().contains(q) || $0.text.lowercased().contains(q) }
    }

    @ViewBuilder private func block(_ b: HelpSection.Block) -> some View {
        switch b {
        case .paragraph(let t):
            Text(Self.inline(t)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        case .bullet(let t):
            HStack(alignment: .firstTextBaseline, spacing: Grid.s) {
                Text("•").foregroundStyle(.secondary)
                Text(Self.inline(t)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            .padding(.leading, Grid.s)
        case .numbered(let n, let t):
            HStack(alignment: .firstTextBaseline, spacing: Grid.s) {
                Text("\(n).").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 18, alignment: .trailing)
                Text(Self.inline(t)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        case .table(let rows):
            SwiftUI.Grid(alignment: .leading, horizontalSpacing: Grid.l, verticalSpacing: Grid.xs) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    GridRow {
                        ForEach(Array(r.enumerated()), id: \.offset) { j, c in
                            Text(Self.inline(c))
                                .font(i == 0 ? .callout.weight(.semibold) : (j == 0 ? .body.monospaced() : .body))
                                .foregroundStyle(i == 0 ? .secondary : .primary)
                        }
                    }
                    if i == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
            .padding(Grid.m)
            .background(ModernCardBackground(radius: 10, accent: false))
        }
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

struct HelpSection: Identifiable, Hashable {
    enum Block: Hashable { case paragraph(String), bullet(String), numbered(Int, String), table([[String]]) }
    var id: String { title }
    let title: String
    let blocks: [Block]
    let text: String

    var symbol: String {
        let t = title.lowercased()
        let map: [(String, String)] = [("überblick", "sparkles"), ("overview", "sparkles"), ("erste", "flag.checkered"), ("getting started", "flag.checkered"),
            ("starting a task", "paperplane"), ("while", "waveform.path.ecg"), ("approvals", "hand.raised"), ("reviewing", "arrow.triangle.merge"),
            ("projects", "square.grid.2x2"), ("extensions", "wand.and.stars"), ("locally", "laptopcomputer"), ("usage", "gauge.with.dots.needle.33percent"),
            ("menu bar", "menubar.rectangle"), ("voice", "mic"), ("sprach", "mic"), ("shortcuts", "keyboard"), ("privacy", "lock.shield"), ("wrong", "lifepreserver"),
            ("auftrag starten", "paperplane"),
            ("während", "waveform.path.ecg"), ("freigaben", "hand.raised"), ("änderungen", "arrow.triangle.merge"),
            ("projekte", "square.grid.2x2"), ("skills", "wand.and.stars"), ("mods", "bolt.badge.automatic"),
            ("lokal", "laptopcomputer"), ("verbrauch", "gauge.with.dots.needle.33percent"), ("mail", "tray.2"),
            ("menüleiste", "menubar.rectangle"), ("tasten", "keyboard"), ("updates", "arrow.down.circle"),
            ("datenschutz", "lock.shield"), ("hakt", "lifepreserver")]
        return map.first { t.contains($0.0) }?.1 ?? "book"
    }

    /// Datei aus der App, sonst aus dem Projektordner (Entwickler-Version).
    static func load() -> [HelpSection] {
        // Deutsch oder Englisch – wie die App
        let file = (Locale.preferredLanguages.first ?? "en").hasPrefix("de") ? "HILFE" : "HELP"
        let url = Bundle.main.url(forResource: file, withExtension: "md")
            ?? Paths.source.appendingPathComponent("docs/\(file).md")
        guard let md = try? String(contentsOf: url, encoding: .utf8) else {
            return [HelpSection(title: L("Hilfe"), blocks: [.paragraph(L("Die Hilfe konnte nicht geladen werden."))], text: "")]
        }
        return parse(md)
    }

    static func parse(_ md: String) -> [HelpSection] {
        var out: [HelpSection] = []
        var title = L("Überblick"), blocks: [Block] = [], text = "", para: [String] = [], table: [[String]] = []
        func flushPara() { if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: " "))); para = [] } }
        func flushTable() { if !table.isEmpty { blocks.append(.table(table)); table = [] } }
        func flushSection() {
            flushPara(); flushTable()
            if !blocks.isEmpty { out.append(HelpSection(title: title, blocks: blocks, text: text)) }
            blocks = []; text = ""
        }
        for raw in md.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ") { continue }                       // Dokument-Titel
            if line.hasPrefix("## ") { flushSection(); title = String(line.dropFirst(3)); continue }
            text += line + "\n"
            if line.hasPrefix("|") {
                flushPara()
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { table.append(cells) }
                continue
            }
            flushTable()
            if line.isEmpty { flushPara(); continue }
            if line.hasPrefix("- ") { flushPara(); blocks.append(.bullet(String(line.dropFirst(2)))); continue }
            if let dot = line.firstIndex(of: "."), let n = Int(line[..<dot]), line[line.index(after: dot)...].hasPrefix(" ") {
                flushPara(); blocks.append(.numbered(n, String(line[line.index(dot, offsetBy: 2)...]))); continue
            }
            para.append(line)
        }
        flushSection()
        return out
    }
}
