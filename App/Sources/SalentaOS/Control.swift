import AgenticOSKit
import SwiftUI

// Browser- und Computer-Steuerung mit Zeitlimit.
// Bevor ein Agent deinen Browser oder deinen Mac steuert, fragt Salenta Code einmal: 15 Minuten, 1 Stunde oder den ganzen Tag?
// Die Freigabe steht in data/approvals/grants.json – bin/aos-mcp liest sie bei jeder Aktion.
// Auch während der Freigabe fragen Absenden, Kaufen, Bezahlen, Löschen und Posten weiter einzeln nach.

enum ControlScope: String, CaseIterable, Identifiable {
    case browser, computer
    var id: String { rawValue }
    var name: String { self == .browser ? L("Browser-Steuerung") : L("Computer-Steuerung") }
    var icon: String { self == .browser ? "safari" : "cursorarrow.rays" }
    var ask: String { self == .browser ? L("Dein Agent möchte deinen Browser steuern") : L("Dein Agent möchte deinen Mac steuern") }
    var explain: String {
        self == .browser
            ? L("Seiten öffnen, lesen, klicken und tippen. Absenden, Kaufen, Bezahlen, Löschen und Posten fragen weiter einzeln.")
            : L("Bildschirm sehen, Apps bedienen, klicken und tippen. Absenden, Kaufen, Bezahlen, Löschen und Posten fragen weiter einzeln.")
    }
}

enum ControlGrants {
    static var file: URL { Paths.data.appendingPathComponent("approvals/grants.json") }

    static func read() -> [String: Double] {
        guard let d = try? Data(contentsOf: file), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }
    static func until(_ s: ControlScope) -> Date? {
        guard let t = read()[s.rawValue], t > Date().timeIntervalSince1970 else { return nil }
        return Date(timeIntervalSince1970: t)
    }
    static func set(_ s: ControlScope, until: Date?) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var g = read().filter { $0.value > Date().timeIntervalSince1970 }
        g[s.rawValue] = until?.timeIntervalSince1970
        if let d = try? JSONSerialization.data(withJSONObject: g) {
            try? d.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    /// Die Zeiträume, die du wählen kannst – wie beim Auto-Modus fürs Coden.
    static var choices: [(String, () -> Date)] {
        [(L("15 Minuten"), { Date().addingTimeInterval(900) }),
         (L("1 Stunde"), { Date().addingTimeInterval(3600) }),
         (L("Ganzen Tag"), { Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: Date()) ?? Date().addingTimeInterval(3600) })]
    }
}

/// Leiste oben: „Dein Agent möchte deinen Browser steuern“ – für wie lange?
struct ControlAccessBar: View {
    @EnvironmentObject private var approvals: ApprovalCenter
    let request: ApprovalRequest
    let scope: ControlScope
    let more: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.s) {
            HStack(spacing: Grid.m) {
                Image(systemName: scope.icon).foregroundStyle(.orange).font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(scope.ask).font(.headline)
                    Text(scope.explain).font(.caption).foregroundStyle(.secondary)
                    if more > 0 { Text(String(format: L("%d weitere warten"), more)).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button(L("Ablehnen")) { approvals.decide(request, allow: false) }
                ForEach(Array(ControlGrants.choices.enumerated()), id: \.offset) { i, c in
                    Button(c.0) {
                        ControlGrants.set(scope, until: c.1())
                        approvals.decide(request, allow: true)
                    }
                    .buttonStyle(.borderedProminent).tint(i == 2 ? .orange : .accentColor)
                }
            }
            if let first = request.input.first(where: { $0.key != "_zugriff" }) {
                Text(first.key + ": " + first.value).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(Grid.m)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.orange.opacity(0.5)))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .frame(maxWidth: 860)
        .padding(Grid.m)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Schalter unter dem Eingabefeld: Steuerung vorab freigeben oder beenden – sichtbar, solange sie läuft.
struct ControlButton: View {
    @State private var tick = Date()
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private func activeText(_ s: ControlScope, _ u: Date, many: Bool) -> String {
        let name: String = many ? L("Steuerung") : s.name
        let time: String = u.formatted(date: .omitted, time: .shortened)
        return name + " " + L("bis") + " " + time
    }

    var body: some View {
        let active = ControlScope.allCases.compactMap { s in ControlGrants.until(s).map { (s, $0) } }
        Menu {
            ForEach(ControlScope.allCases) { s in
                Section(s.name) {
                    if let u = ControlGrants.until(s) {
                        Text(L("Frei bis ") + u.formatted(date: .omitted, time: .shortened))
                        Button(L("Jetzt beenden")) { ControlGrants.set(s, until: nil); tick = Date() }
                    } else {
                        Text(L("Fragt vor der ersten Aktion"))
                    }
                    ForEach(Array(ControlGrants.choices.enumerated()), id: \.offset) { _, c in
                        Button(L("Freigeben: ") + c.0) { ControlGrants.set(s, until: c.1()); tick = Date() }
                    }
                }
            }
        } label: {
            if let a = active.first {
                Label(activeText(a.0, a.1, many: active.count > 1), systemImage: active.count > 1 ? "hand.point.up.left.fill" : a.0.icon)
                    .foregroundStyle(.orange)
            } else {
                Label(L("Steuerung"), systemImage: "hand.point.up.left")
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
        .font(.caption)
        .id(tick)
        .onReceive(timer) { tick = $0 }
        .help(L("Browser- und Computer-Steuerung: Salenta Code fragt vor der ersten Aktion, für wie lange – 15 Minuten, 1 Stunde oder den ganzen Tag."))
    }
}
