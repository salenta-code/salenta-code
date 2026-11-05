import Foundation

/// Macht aus einer Zeile eine Aufgabe.
///   "Angebot schreiben #arbeit ! morgen"     -> Arbeit, hoch, fällig morgen
///   "Login-Bug fixen #arbeit @claude heute"  -> Arbeit, an Claude Code, heute
///   "Steuer-Unterlagen 15.11. #privat"       -> fällig 15.11.
/// Tags: #firma, ! oder !! = hoch, !niedrig, heute, morgen, Wochentag (mo, di, mi, do, fr, sa, so),
/// TT.MM. oder TT.MM.JJJJ, @claude / @codex.
public enum QuickCapture {
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> TaskItem {
        var task = TaskItem(title: "")
        var words: [String] = []
        let today = calendar.startOfDay(for: now)

        for raw in text.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let word = String(raw)
            let lower = word.lowercased()

            if lower.hasPrefix("#"), let company = Company.from(tag: String(lower.dropFirst())) {
                task.company = company
                continue
            }
            if lower == "!" || lower == "!!" || lower == "!hoch" || lower == "!wichtig" {
                task.priority = .hoch
                continue
            }
            if lower == "!niedrig" || lower == "!später" {
                task.priority = .niedrig
                continue
            }
            if lower.hasPrefix("@"), let agent = AgentKind(rawValue: String(lower.dropFirst())) {
                task.agent = agent
                continue
            }
            if lower == "heute" {
                task.due = today
                continue
            }
            if lower == "morgen" {
                task.due = calendar.date(byAdding: .day, value: 1, to: today)
                continue
            }
            if lower == "übermorgen" {
                task.due = calendar.date(byAdding: .day, value: 2, to: today)
                continue
            }
            if let weekday = weekdays[lower] {
                task.due = nextDate(weekday: weekday, after: today, calendar: calendar)
                continue
            }
            if let date = parseGermanDate(lower, today: today, calendar: calendar) {
                task.due = date
                continue
            }
            words.append(word)
        }

        task.title = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if task.title.isEmpty { task.title = text.trimmingCharacters(in: .whitespaces) }

        if let due = task.due {
            let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: due)).day ?? 0
            if days <= 0 {
                task.status = .heute
            } else if days <= 6 {
                task.status = .woche
            }
        }
        if task.agent != nil, task.status == .inbox { task.status = .heute }
        return task
    }

    // Calendar weekday: 1 = Sonntag … 7 = Samstag
    static let weekdays: [String: Int] = [
        "mo": 2, "montag": 2, "di": 3, "dienstag": 3, "mi": 4, "mittwoch": 4,
        "do": 5, "donnerstag": 5, "fr": 6, "freitag": 6, "sa": 7, "samstag": 7,
        "so": 1, "sonntag": 1,
    ]

    static func nextDate(weekday: Int, after today: Date, calendar: Calendar) -> Date? {
        let current = calendar.component(.weekday, from: today)
        var diff = weekday - current
        if diff <= 0 { diff += 7 }
        return calendar.date(byAdding: .day, value: diff, to: today)
    }

    /// "15.11." / "15.11" / "15.11.2026" / "15.11.26"
    static func parseGermanDate(_ s: String, today: Date, calendar: Calendar) -> Date? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let day = Int(parts[0]), let month = Int(parts[1]),
              (1...31).contains(day), (1...12).contains(month) else { return nil }
        let thisYear = calendar.component(.year, from: today)
        var year = thisYear
        if parts.count == 3, let y = Int(parts[2]) { year = y < 100 ? 2000 + y : y }
        var comps = DateComponents(year: year, month: month, day: day)
        guard var date = calendar.date(from: comps) else { return nil }
        // Ohne Jahr und schon vorbei: nächstes Jahr.
        if parts.count == 2, date < today {
            comps.year = thisYear + 1
            date = calendar.date(from: comps) ?? date
        }
        return date
    }
}
