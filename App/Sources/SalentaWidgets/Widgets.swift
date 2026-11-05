import SwiftUI
import WidgetKit

// Salenta Code – echte Mac-Widgets (Schreibtisch und Mitteilungszentrale, über „Widgets bearbeiten“ hinzufügen).
// Die App schreibt alle 30 s einen kleinen Stand nach ~/Library/Application Support/ai.salenta.os/widget/feed.json;
// die Widgets lesen nur diese Datei (abgeschottet, nur Lesezugriff auf genau diesen Ordner).

struct Feed: Codable {
    struct Run: Codable, Hashable { var id: String; var title: String; var agent: String; var since: Date }
    struct Project: Codable, Hashable { var name: String; var running: Int; var review: Int; var red: Int; var queued: Int }
    var running: [Run] = []
    var needsYou = 0
    var approvals = 0
    var finished = 0
    var claude: Double?          // 0…1 Auslastung des 5-Stunden-Fensters
    var codex: Double?
    var awakeUntil: Date?
    var projects: [Project] = []
    var night = 0
    var updated = Date.distantPast

    static var url: URL {
        let home = String(cString: getpwuid(getuid()).pointee.pw_dir)   // echtes Home, nicht der Sandbox-Container
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/ai.salenta.os/widget/feed.json")
    }

    static func load() -> Feed? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(Feed.self, from: d)
    }

    static let sample = Feed(running: [Run(id: "1", title: "Login-Seite überarbeiten", agent: "Claude Code", since: Date().addingTimeInterval(-900)),
                                       Run(id: "2", title: "Tests reparieren", agent: "Codex", since: Date().addingTimeInterval(-300))],
                             needsYou: 2, approvals: 1, finished: 3, claude: 0.42, codex: 0.18,
                             projects: [Project(name: "salenta", running: 2, review: 1, red: 0, queued: 3)], updated: Date())
}

struct FeedEntry: TimelineEntry {
    let date: Date
    let feed: Feed?
}

struct FeedProvider: TimelineProvider {
    func placeholder(in context: Context) -> FeedEntry { FeedEntry(date: Date(), feed: .sample) }
    func getSnapshot(in context: Context, completion: @escaping (FeedEntry) -> Void) {
        completion(FeedEntry(date: Date(), feed: context.isPreview ? .sample : (Feed.load() ?? .sample)))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<FeedEntry>) -> Void) {
        // Die App stößt bei Änderungen selbst ein Neuladen an; zur Sicherheit alle 5 Minuten.
        completion(Timeline(entries: [FeedEntry(date: Date(), feed: Feed.load())], policy: .after(Date().addingTimeInterval(300))))
    }
}

// MARK: - Bausteine

struct Pulse: Shape {
    func path(in rect: CGRect) -> Path {
        let pts: [CGPoint] = [CGPoint(x: 118, y: 256), CGPoint(x: 208, y: 256), CGPoint(x: 236, y: 168), CGPoint(x: 276, y: 344),
                              CGPoint(x: 316, y: 136), CGPoint(x: 348, y: 256), CGPoint(x: 394, y: 256)]
        let s = min(rect.width, rect.height) / 512
        let ox = rect.midX - 256 * s, oy = rect.midY - 256 * s
        var p = Path()
        for (i, pt) in pts.enumerated() {
            let q = CGPoint(x: ox + pt.x * s, y: oy + pt.y * s)
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        return p
    }
}

struct Mark: View {
    var size: CGFloat = 18
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.223, style: .continuous).fill(Color.black.opacity(0.85))
            Pulse().stroke(Color.white, style: StrokeStyle(lineWidth: size * 34 / 512, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .widgetAccentable()
    }
}

struct Header: View {
    let title: String
    var body: some View {
        HStack(spacing: 5) {
            Mark()
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

struct Ring: View {
    let value: Double
    let label: String
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 6)
                Circle().trim(from: 0, to: min(max(value, 0), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .widgetAccentable()
                Text("\(Int(value * 100))%").font(.caption.weight(.semibold)).monospacedDigit()
            }
            .frame(width: 52, height: 52)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var color: Color { value >= 0.9 ? .red : value >= 0.6 ? .orange : .green }
}

struct Missing: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Header(title: "Salenta Code")
            Spacer()
            Text("Salenta Code öffnen, damit hier etwas erscheint.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension View {
    /// Glas-Look: die Systemfläche des Widgets bleibt sichtbar, darüber nur ein Hauch Füllung.
    func glass() -> some View {
        containerBackground(for: .widget) { Rectangle().fill(.fill.quaternary) }
    }
}

// MARK: - Agents

struct AgentsView: View {
    let entry: FeedEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let f = entry.feed {
            VStack(alignment: .leading, spacing: 6) {
                Header(title: "Agents")
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(f.running.count)").font(.system(size: 34, weight: .semibold, design: .rounded)).contentTransition(.numericText())
                    Text(f.running.count == 1 ? "arbeitet" : "arbeiten").font(.callout).foregroundStyle(.secondary)
                }
                if f.needsYou > 0 {
                    Label("\(f.needsYou) brauchen dich", systemImage: "hand.raised.fill").font(.caption.weight(.medium)).foregroundStyle(.orange)
                } else if f.finished > 0 {
                    Label("\(f.finished) fertig", systemImage: "checkmark.circle.fill").font(.caption.weight(.medium)).foregroundStyle(.green)
                }
                if family != .systemSmall {
                    ForEach(f.running.prefix(family == .systemLarge ? 8 : 3), id: \.self) { r in
                        HStack(spacing: 6) {
                            Circle().fill(.green).frame(width: 6, height: 6).widgetAccentable()
                            Text(r.title).font(.caption).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(r.since, style: .relative).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .widgetURL(URL(string: f.needsYou > 0 ? "salentacode://cockpit" : "salentacode://mission"))
        } else { Missing() }
    }
}

struct AgentsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "agents", provider: FeedProvider()) { e in AgentsView(entry: e).glass() }
            .configurationDisplayName("Agents")
            .description("Was deine Agents gerade tun – und was dich braucht.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Verbrauch

struct UsageView: View {
    let entry: FeedEntry
    var body: some View {
        if let f = entry.feed {
            VStack(alignment: .leading, spacing: 8) {
                Header(title: "Verbrauch")
                HStack(spacing: 14) {
                    if let c = f.claude { Ring(value: c, label: "Claude") }
                    if let c = f.codex { Ring(value: c, label: "Codex") }
                    if f.claude == nil && f.codex == nil { Text("Noch keine Daten").font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }
            .widgetURL(URL(string: "salentacode://usage"))
        } else { Missing() }
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "usage", provider: FeedProvider()) { e in UsageView(entry: e).glass() }
            .configurationDisplayName("Verbrauch")
            .description("Wie voll das 5-Stunden-Fenster von Claude und Codex ist.")
            .supportedFamilies([.systemSmall])
    }
}

// MARK: - Projekt-Betreuer

struct StewardsView: View {
    let entry: FeedEntry
    var body: some View {
        if let f = entry.feed {
            VStack(alignment: .leading, spacing: 6) {
                Header(title: "Projekt-Betreuer")
                if f.projects.isEmpty {
                    Text("Noch kein Projekt in Betreuung.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(f.projects.prefix(4), id: \.self) { p in
                    HStack(spacing: 8) {
                        Text(p.name).font(.callout.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        if p.running > 0 { chip("\(p.running)", "bolt.fill", .blue) }
                        if p.review > 0 { chip("\(p.review)", "checkmark.seal.fill", .green) }
                        if p.red > 0 { chip("\(p.red)", "xmark.octagon.fill", .red) }
                        if p.queued > 0 { chip("\(p.queued)", "clock", .secondary) }
                    }
                }
                Spacer(minLength: 0)
                if f.night > 0 { Label("\(f.night) für die Nachtschicht", systemImage: "moon.stars").font(.caption2).foregroundStyle(.secondary) }
            }
            .widgetURL(URL(string: "salentacode://stewards"))
        } else { Missing() }
    }

    private func chip(_ t: String, _ icon: String, _ c: Color) -> some View {
        Label(t, systemImage: icon).font(.caption2.weight(.semibold)).foregroundStyle(c).labelStyle(.titleAndIcon)
    }
}

struct StewardsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "stewards", provider: FeedProvider()) { e in StewardsView(entry: e).glass() }
            .configurationDisplayName("Projekt-Betreuer")
            .description("Deine betreuten Projekte: was läuft, was fertig ist, was rot ist.")
            .supportedFamilies([.systemMedium])
    }
}

@main
struct SalentaWidgets: WidgetBundle {
    var body: some Widget {
        AgentsWidget()
        UsageWidget()
        StewardsWidget()
    }
}
