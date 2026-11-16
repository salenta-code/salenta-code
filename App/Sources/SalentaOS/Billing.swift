import AgenticOSKit
import SwiftUI

// Kostenschutz: Agents, die pro Nutzung abrechnen (API statt Abo), werden nie still automatisch gewählt –
// weder von der Agentenwahl noch beim Ausweichen im Limit, beim Nachbessern, beim Betreuer oder in Vorschlägen.
// Wählst du sie selbst, laufen sie wie gewohnt. Laufzeit und Anzahl der Läufe werden pro Monat mitgezählt.

enum Billing {
    /// Ab Werk pro Nutzung: Junie (JetBrains-Guthaben/API) und OpenRouter (Guthaben).
    static let defaultMetered: Set<AgentKind> = [.junie, .openrouter, .deepseek, .harness]   // DeepSeek Harness rechnet über die API ab
    static let d = UserDefaults.standard

    static func isMetered(_ a: AgentKind) -> Bool {
        // Der Salenta Harness rechnet nur mit Schlüssel pro Nutzung ab; läuft er über dein Abo, kostet er nichts extra
        if a == .harness, d.object(forKey: "billing.metered.harness") == nil { return HarnessSetup.hasKey }
        return d.object(forKey: "billing.metered." + a.rawValue) as? Bool ?? defaultMetered.contains(a)
    }
    static func setMetered(_ a: AgentKind, _ on: Bool) { d.set(on, forKey: "billing.metered." + a.rawValue) }

    /// Dürfen Agents mit Kosten pro Nutzung automatisch gewählt werden? Ab Werk nein.
    static var autoAllowed: Bool {
        get { d.object(forKey: "billing.auto") as? Bool ?? false }
        set { d.set(newValue, forKey: "billing.auto") }
    }

    /// Darf die App diesen Agent von sich aus nehmen?
    static func autoOK(_ a: AgentKind) -> Bool { !isMetered(a) || autoAllowed }

    // MARK: Mitzählen

    struct Month: Codable { var runs: [String: Int] = [:]; var seconds: [String: Double] = [:] }
    static var monthKey: String { let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f.string(from: Date()) }

    static func load() -> [String: Month] {
        guard let data = d.data(forKey: "billing.months"), let m = try? JSONDecoder().decode([String: Month].self, from: data) else { return [:] }
        return m
    }

    static func record(_ a: AgentKind, seconds: TimeInterval) {
        guard isMetered(a), seconds > 0 else { return }
        var all = load()
        var m = all[monthKey] ?? Month()
        m.runs[a.rawValue, default: 0] += 1
        m.seconds[a.rawValue, default: 0] += seconds
        all[monthKey] = m
        all = all.filter { $0.key >= String(monthKey.prefix(4)) + "-01" || all.count < 13 }
        if let data = try? JSONEncoder().encode(all) { d.set(data, forKey: "billing.months") }
    }

    /// Wo du die echten Kosten siehst.
    static func billingURL(_ a: AgentKind) -> URL? {
        switch a {
        case .junie: URL(string: "https://account.jetbrains.com/licenses")
        case .openrouter: URL(string: "https://openrouter.ai/activity")
        case .gemini: URL(string: "https://aistudio.google.com/usage")
        case .grok: URL(string: "https://console.x.ai")
        default: nil
        }
    }
}

/// Karte auf der Verbrauch-Seite: was pro Nutzung kostet, wie viel diesen Monat lief, Schalter.
struct BillingCard: View {
    @State private var auto = Billing.autoAllowed
    @State private var tick = 0

    var body: some View {
        let month = Billing.load()[Billing.monthKey] ?? Billing.Month()
        let metered = AgentKind.coders.filter { Billing.isMetered($0) && OpenModels.available($0) }
        Card(title: L("Kosten pro Nutzung (API)"), symbol: "eurosign.circle") {
            VStack(alignment: .leading, spacing: Grid.s) {
                Text("Diese Agents rechnen nicht über ein Abo ab, sondern pro Nutzung. Salenta Code nimmt sie nie von sich aus – nur wenn du sie selbst auswählst.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if metered.isEmpty {
                    Text("Kein Agent mit Kosten pro Nutzung installiert.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(metered, id: \.self) { a in
                    let runs = month.runs[a.rawValue] ?? 0, secs = month.seconds[a.rawValue] ?? 0
                    HStack {
                        Label(a.title, systemImage: a.symbol)
                        Spacer()
                        Text(runs == 0 ? L("diesen Monat nicht genutzt")
                                       : String(format: L("%d Läufe · %@ diesen Monat"), runs, Self.duration(secs)))
                            .font(.callout.monospacedDigit()).foregroundStyle(runs > 0 ? .orange : .secondary)
                        if let u = Billing.billingURL(a) {
                            Link(destination: u) { Image(systemName: "arrow.up.right.square") }.help(L("Echte Kosten beim Anbieter ansehen"))
                        }
                    }
                }
                Toggle(L("Automatisch nutzen erlauben (kann Geld kosten)"), isOn: $auto)
                    .onChange(of: auto) { _, v in Billing.autoAllowed = v }
                    .help(L("An: Die Agentenwahl darf diese Agents auch selbst nehmen, z. B. beim Nachbessern oder im Limit. Aus (empfohlen): nur wenn du sie auswählst."))
                DisclosureGroup(L("Welche Agents kosten pro Nutzung?")) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(AgentKind.coders.filter { OpenModels.available($0) && $0 != .ollama }, id: \.self) { a in
                            Toggle(a.title, isOn: Binding(get: { Billing.isMetered(a) }, set: { Billing.setMetered(a, $0); tick += 1 }))
                        }
                        Text("Hast du einen Agent über einen eigenen API-Schlüssel statt über ein Abo angemeldet, schalte ihn hier ein.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
                .font(.callout)
            }
            .id(tick)
        }
    }

    static func duration(_ s: Double) -> String {
        let m = Int(s / 60)
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(max(m, 1)) min"
    }
}

// MARK: - Agents an- und abschalten

/// Agents, die du nicht mehr nutzt (z. B. Abo gekündigt), abschalten: Sie verschwinden aus Auswahl, Agentenwahl,
/// Ausweichlisten, Betreuer, Vorschlägen und Modelllisten – das Programm selbst bleibt unangetastet.
enum AgentOff {
    static let key = "agents.disabled"
    static var off: Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    static func isOff(_ a: AgentKind) -> Bool { off.contains(a.rawValue) }
    static func set(_ a: AgentKind, on: Bool) {
        var s = off
        if on { s.remove(a.rawValue) } else { s.insert(a.rawValue) }
        UserDefaults.standard.set(Array(s).sorted(), forKey: key)
        Detection.forget(a.command)
        NotificationCenter.default.post(name: Secrets.changed, object: nil)   // Auswahl überall neu aufbauen
    }
    /// Programm ist da (unabhängig vom Schalter)?
    static func present(_ a: AgentKind) -> Bool {
        switch a {
        case .openrouter: return OpenModels.hasOpenRouter
        case .ollama: return OllamaApp.installed
        case .shell: return false
        default: return Detection.which(a.command) != nil
        }
    }
}

/// Einstellungen: welche Agents Salenta Code nutzen darf.
struct AgentConnections: View {
    @State private var tick = 0

    var body: some View {
        Section("Verbundene Agents") {
            let present = AgentKind.coders.filter { AgentOff.present($0) }
            if present.isEmpty { Text("Noch kein Coding-Agent gefunden.").foregroundStyle(.secondary) }
            ForEach(present, id: \.self) { a in
                Toggle(isOn: Binding(get: { !AgentOff.isOff(a) }, set: { AgentOff.set(a, on: $0); tick += 1 })) {
                    HStack(spacing: 6) {
                        Image(systemName: a.symbol).frame(width: 18)
                        Text(a.title)
                        if Billing.isMetered(a) { Text(L("kostet pro Nutzung")).font(.caption2).foregroundStyle(.orange) }
                        if AgentHealth.needsLogin(a) { Text(L("nicht angemeldet")).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }
            Text("Aus = Salenta Code nutzt diesen Agent nirgends mehr – nicht in der Auswahl, nicht automatisch, keine Modelle in den Listen. Gut, wenn du z. B. ein Abo gekündigt hast. Das Programm selbst bleibt installiert; einschalten geht jederzeit.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .id(tick)
    }
}
