import AgenticOSKit
import SwiftUI

/// Karte mit Titel, Symbol und optionaler Zahl.
struct SCard<Content: View>: View {
    let title: String
    var count: Int? = nil
    var symbol: String
    var tint: Color = .secondary
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.m) {
            HStack(spacing: Grid.s) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).font(.headline)
                if let count { Text("\(count)").font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2).background(tint.opacity(0.15), in: Capsule()) }
                Spacer()
            }
            content()
        }
        .padding(Grid.l)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

struct EmptyHint: View {
    let text: String
    var body: some View { Text(text).font(.callout).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading) }
}

func relativeDay(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return d.timeString }
    if cal.isDateInYesterday(d) { return L("gestern") }
    return d.formatted(.dateTime.day().month(.abbreviated))
}
/// Tipps & Tricks: eine kleine Karte mit wechselnden Hinweisen. „Nächster“ blättert, ✕ blendet sie aus.
struct TipsCard: View {
    @AppStorage("tips.index") private var index = 0
    @AppStorage("tips.hidden") private var hidden = false

    static let tips: [(String, String)] = [
        ("questionmark.bubble", "Nur eine Frage? Stell im Eingabefeld auf „Fragen“ – der Agent liest den Code und antwortet, ohne etwas zu ändern. Fragen mit „?“ erkennt Salenta Code auch von selbst."),
        ("list.bullet.clipboard", "Großer Umbau? Unter + „Erst planen, dann umsetzen“ einschalten. Du bekommst zuerst einen Plan und gibst ihn frei."),
        ("play.display", "„Vorher ausprobieren“ startet die App mit den Änderungen des Agents – dein Projekt bleibt unberührt, bis du übernimmst."),
        ("square.split.3x1", "Unter + „Parallel lösen“ bearbeiten 2 oder 3 Agents denselben Auftrag. Danach vergleichst du und nimmst die beste Lösung."),
        ("photo.on.rectangle", "⇧⌘V hängt einen Screenshot aus der Zwischenablage an den Auftrag – ideal für Fehler und Design-Wünsche."),
        ("shield.lefthalf.filled", "Projektregeln (Schild-Symbol auf der Projektkarte) gelten für jeden Agent – z. B. „Keine neuen Abhängigkeiten“ oder „Tests immer mit pnpm“."),
        ("brain.head.profile", "Projektwissen: Was ein Agent in einem Projekt lernt, wissen beim nächsten Auftrag auch alle anderen."),
        ("cpu", "Eigenes Modell pro Agent: Wähl es im Eingabefeld beim Agent. Deine Wahl gilt immer vor der automatischen Auswahl."),
        ("arrow.triangle.pull", "„Pull Request …“ schreibt Titel, Beschreibung und Changelog selbst – ein Klick und er liegt auf GitHub."),
        ("command", "⌘K öffnet die Befehlspalette: Projekte, Aufträge und Einstellungen in Sekunden finden."),
        ("wifi.slash", "Kein Internet? Mit einem lokalen Modell (Einstellungen › Modelle › Lokal) laufen kleine Aufträge offline weiter."),
        ("checkmark.seal", "Nach jedem Auftrag prüft Salenta Code automatisch Build, Tests und Review – genau wie die CI auf GitHub."),
    ]

    var body: some View {
        if !hidden {
            let t = Self.tips[((index % Self.tips.count) + Self.tips.count) % Self.tips.count]
            HStack(alignment: .top, spacing: Grid.s) {
                Image(systemName: t.0).font(.title3).foregroundStyle(.yellow).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tipp").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(L(t.1)).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Grid.s)
                Button { withAnimation(.snappy) { index += 1 } } label: { Label(L("Nächster Tipp"), systemImage: "arrow.right") }
                    .controlSize(.small)
                Button { hidden = true } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Tipps ausblenden (Einstellungen › Allgemein holt sie zurück)"))
            }
            .padding(Grid.m)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.yellow.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.yellow.opacity(0.25)))
            .onAppear { index += 1 }   // bei jedem Öffnen ein neuer Tipp
        }
    }
}
