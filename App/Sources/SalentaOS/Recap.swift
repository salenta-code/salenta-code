import AgenticOSKit
import AppKit
import SwiftUI

// Wochenrückblick: Aufträge, Agent-Arbeitszeit, Erfolgsquote, API-Gegenwert und was die Modellwahl gespart hat –
// als teilbare Karte (Bild für LinkedIn/Instagram) und fertiger Post-Text.
// Preise sind eine Schätzung nach Listenpreisen pro Million Tokens und in data/prices.json anpassbar.

struct ModelPrice: Codable {
    var match: String       // Teil des Modellnamens, z. B. "opus"
    var input: Double       // USD je 1 Mio. Tokens
    var output: Double
    var cacheRead: Double
    var cacheWrite: Double
}

enum Prices {
    /// Standardwerte – Listenpreise ändern sich; in data/prices.json überschreibbar.
    static let defaults: [ModelPrice] = [
        ModelPrice(match: "opus", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        ModelPrice(match: "sonnet", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        ModelPrice(match: "haiku", input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25),
        ModelPrice(match: "gpt", input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0),
        ModelPrice(match: "codex", input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0),
        ModelPrice(match: "", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75),
    ]
    static var url: URL { Paths.data.appendingPathComponent("prices.json") }

    static var table: [ModelPrice] {
        if let d = try? Data(contentsOf: url), let t = try? JSONDecoder().decode([ModelPrice].self, from: d), !t.isEmpty { return t }
        if let d = try? JSONEncoder().encode(defaults) { try? d.write(to: url) }   // zum Anpassen anlegen
        return defaults
    }

    static func price(_ model: String, _ t: [ModelPrice]) -> ModelPrice {
        let m = model.lowercased()
        return t.first { !$0.match.isEmpty && m.contains($0.match) } ?? t.first { $0.match.isEmpty } ?? defaults.last!
    }

    static func cost(_ p: UsagePoint, _ price: ModelPrice) -> Double {
        (Double(p.input) * price.input + Double(p.output) * price.output
         + Double(p.cacheRead) * price.cacheRead + Double(p.cacheWrite) * price.cacheWrite) / 1_000_000
    }

    /// Dollar → Euro (grob; in den Einstellungen änderbar)
    static var eurPerUSD: Double { UserDefaults.standard.object(forKey: "recap.eurPerUSD") as? Double ?? 0.92 }
}

struct RecapStats {
    var missions = 0
    var green = 0
    var verified = 0
    var merged = 0
    var agentSeconds: TimeInterval = 0
    var tokens = 0
    var apiValue: Double = 0        // EUR
    var saved: Double = 0           // EUR gegenüber „alles mit dem stärksten Modell“
    var agents: [(String, Int)] = []
    var projects: [String] = []
    var nightGreen = 0
    var from = Date()

    static func week() -> RecapStats {
        var s = RecapStats()
        let start = Calendar.current.startOfDay(for: Date().addingTimeInterval(-6 * 86400))
        s.from = start
        let w = Insights.week(MissionStore.shared.missions)
        s.missions = w.total; s.verified = w.verified; s.green = w.passed; s.merged = w.merged; s.agentSeconds = w.agentSeconds
        s.agents = w.byAgent
        let recent = MissionStore.shared.missions.filter { $0.started >= start && $0.plan != true }
        var dirs: [String: Int] = [:]
        for m in recent { dirs[(Digest.workDir(m) as NSString).lastPathComponent, default: 0] += 1 }
        s.projects = dirs.sorted { $0.value > $1.value }.map(\.key).filter { !$0.isEmpty }
        s.nightGreen = NightShift.shared.report?.green ?? 0
        let table = Prices.table
        let top = Prices.price("opus", table)
        let points = (Usage.shared.claude + Usage.shared.codex).filter { $0.date >= start }
        var api = 0.0, allTop = 0.0
        for p in points {
            s.tokens += p.total
            api += Prices.cost(p, Prices.price(p.model, table))
            allTop += Prices.cost(p, top)
        }
        s.apiValue = api * Prices.eurPerUSD
        s.saved = max(0, allTop - api) * Prices.eurPerUSD
        return s
    }

    var successRate: Int? { verified > 0 ? Int((Double(green) / Double(verified) * 100).rounded()) : nil }
    var hours: String { Insights.duration(agentSeconds) }

    func euro(_ v: Double) -> String { v.formatted(.currency(code: "EUR").precision(.fractionLength(v < 100 ? 2 : 0))) }

    func post(showProjects: Bool) -> String {
        var lines = [
            "Meine Woche mit KI-Agents 🤖",
            "",
            "✅ \(missions) Aufträge erledigt\(successRate.map { " – \($0) % beim Prüfen grün" } ?? "")",
            "⏱️ \(hours) haben die Agents für mich gearbeitet",
        ]
        if merged > 0 { lines.append("🚀 \(merged) Änderungen übernommen") }
        if nightGreen > 0 { lines.append("🌙 \(nightGreen) Aufgaben über Nacht fertig geworden") }
        if apiValue > 1 { lines.append("💶 \(euro(apiValue)) API-Gegenwert – über mein Abo") }
        if saved > 1 { lines.append("💡 \(euro(saved)) gespart, weil nicht jede Aufgabe das teuerste Modell braucht") }
        if !agents.isEmpty { lines.append("🧠 Im Team: " + agents.prefix(4).map(\.0).joined(separator: ", ")) }
        if showProjects, !projects.isEmpty { lines.append("📁 Projekte: " + projects.prefix(3).joined(separator: ", ")) }
        lines += ["", "Gebaut mit Salenta Code – kostenlos und Open Source für den Mac."]
        return lines.joined(separator: "\n")
    }
}

// MARK: - Teilbare Karte (1080 × 1350)

struct RecapCard: View {
    let s: RecapStats
    var showProjects = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.09), Color(white: 0.02)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 36) {
                HStack(spacing: 18) {
                    SalentaMark(size: 72)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Meine Woche mit KI-Agents").font(.system(size: 44, weight: .bold, design: .rounded))
                        Text("\(s.from.formatted(.dateTime.day().month())) – \(Date().formatted(.dateTime.day().month().year()))")
                            .font(.system(size: 26)).foregroundStyle(.white.opacity(0.55))
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 28), GridItem(.flexible(), spacing: 28)], spacing: 28) {
                    tile("\(s.missions)", "Aufträge erledigt", "checkmark.seal.fill", .green)
                    tile(s.hours, "Agents haben gearbeitet", "clock.fill", .blue)
                    tile(s.successRate.map { "\($0) %" } ?? "–", "beim Prüfen grün", "checkmark.shield.fill", .mint)
                    tile(s.apiValue > 1 ? s.euro(s.apiValue) : "\(s.tokens / 1_000_000) Mio.", s.apiValue > 1 ? "API-Gegenwert" : "Tokens", "eurosign.circle.fill", .orange)
                }
                if s.saved > 1 {
                    HStack(spacing: 16) {
                        Image(systemName: "lightbulb.fill").font(.system(size: 34)).foregroundStyle(.yellow)
                        Text("\(s.euro(s.saved)) gespart – nicht jede Aufgabe braucht das teuerste Modell")
                            .font(.system(size: 30, weight: .semibold))
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 28).fill(Color.yellow.opacity(0.12)))
                }
                if !s.agents.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Mein Agent-Team").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                        HStack(spacing: 12) {
                            ForEach(s.agents.prefix(4), id: \.0) { a, n in
                                Text("\(a) · \(n)").font(.system(size: 26, weight: .medium))
                                    .padding(.horizontal, 20).padding(.vertical, 10)
                                    .background(Capsule().fill(.white.opacity(0.1)))
                            }
                        }
                    }
                }
                if showProjects, !s.projects.isEmpty {
                    Text("Projekte: " + s.projects.prefix(3).joined(separator: " · ")).font(.system(size: 26)).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                HStack {
                    Text("Salenta Code").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("· kostenlos & Open Source für den Mac").font(.system(size: 26)).foregroundStyle(.white.opacity(0.55))
                    Spacer()
                }
            }
            .padding(72)
            .foregroundStyle(.white)
        }
        .frame(width: 1080, height: 1350)
    }

    private func tile(_ value: String, _ label: String, _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(tint)
            Text(value).font(.system(size: 64, weight: .bold, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1)
            Text(label).font(.system(size: 26)).foregroundStyle(.white.opacity(0.6))
        }
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 32).fill(.white.opacity(0.07)))
    }
}

// MARK: - Seite

struct RecapView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var usage = Usage.shared
    @State private var stats = RecapStats.week()
    @AppStorage("recap.projects") private var showProjects = false
    @State private var exported: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Grid.l) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Wochenrückblick").font(.largeTitle.weight(.semibold))
                        Text("Was deine Agents in den letzten 7 Tagen geschafft haben – als Bild zum Teilen.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { stats = RecapStats.week() } label: { Label("Aktualisieren", systemImage: "arrow.clockwise") }
                }
                HStack(alignment: .top, spacing: Grid.xl) {
                    RecapCard(s: stats, showProjects: showProjects)
                        .scaleEffect(0.42, anchor: .topLeading)
                        .frame(width: 1080 * 0.42, height: 1350 * 0.42, alignment: .topLeading)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(radius: 12, y: 6)
                    VStack(alignment: .leading, spacing: Grid.m) {
                        Toggle("Projektnamen zeigen", isOn: $showProjects)
                        HStack {
                            Button { exported = export() } label: { Label("Als Bild sichern", systemImage: "square.and.arrow.down") }
                                .buttonStyle(.borderedProminent)
                            if let u = exported {
                                ShareLink(item: u) { Label("Teilen", systemImage: "square.and.arrow.up") }
                            }
                        }
                        if let u = exported {
                            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([u]) }.buttonStyle(.link)
                        }
                        Divider()
                        Text("Post-Text").font(.headline)
                        Text(stats.post(showProjects: showProjects)).font(.callout).textSelection(.enabled)
                            .padding(Grid.m).background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(stats.post(showProjects: showProjects), forType: .string)
                            app.show("✓ " + L("Text kopiert"))
                        } label: { Label("Text kopieren", systemImage: "doc.on.doc") }
                        Divider()
                        Text("API-Gegenwert und Ersparnis sind Schätzungen nach Listenpreisen pro Million Tokens (Claude Code und Codex). Wenn sich Preise ändern: data/prices.json anpassen.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Preistabelle öffnen") { _ = Prices.table; NSWorkspace.shared.open(Prices.url) }.buttonStyle(.link).font(.caption)
                    }
                    .frame(maxWidth: 420, alignment: .leading)
                }
            }
            .padding(Grid.xl)
        }
        .navigationTitle("Wochenrückblick")
        .onChange(of: usage.claude.count) { _, _ in stats = RecapStats.week() }
    }

    @MainActor
    private func export() -> URL? {
        let r = ImageRenderer(content: RecapCard(s: stats, showProjects: showProjects))
        r.scale = 1
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let u = dir.appendingPathComponent("Salenta-Code-Wochenrueckblick-\(Date().formatted(.iso8601.year().month().day())).png")
        do { try png.write(to: u); app.show("✓ " + L("Gesichert in Downloads")); return u } catch { app.show(L("Konnte nicht sichern")); return nil }
    }
}
