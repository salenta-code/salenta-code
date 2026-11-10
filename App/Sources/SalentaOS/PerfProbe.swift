import AgenticOSKit
import AppKit
import SwiftUI

// Leistungs-Messung (Probe): misst, was Salenta Code und alles, was es gestartet hat, gerade an CPU, Speicher und
// Energie kostet – plus wo der Hauptthread seine Zeit verbringt. Ergebnis: logs/perf.txt.
// Auslösen: Menü „Hilfe › Leistung messen“, oder Befehl „leistung_messen“ über die Brücke.

enum PerfProbe {
    static var running = false

    static func run(completion: ((URL) -> Void)? = nil) {
        guard !running else { return }
        running = true
        let me = ProcessInfo.processInfo.processIdentifier
        DispatchQueue.global(qos: .utility).async {
            var out = "Salenta Code – Leistung \(DateCoding.stamp(Date()))\n"
            out += "Mac: \(ProcessInfo.processInfo.activeProcessorCount) Kerne, Thermal: \(ProcessInfo.processInfo.thermalState.rawValue), "
            out += "Stromsparen: \(ProcessInfo.processInfo.isLowPowerModeEnabled)\n\n"

            // 1. eigene CPU-Zeit über 10 s (ohne Kindprozesse)
            let t0 = cpuSeconds(), w0 = Date()
            Thread.sleep(forTimeInterval: 10)
            let own = (cpuSeconds() - t0) / Date().timeIntervalSince(w0) * 100
            out += String(format: "Salenta Code selbst: %.1f %% CPU (Mittel über 10 s, 100 %% = ein Kern), Speicher %d MB\n\n", own, CrashLog.residentMB())

            // 2. alle Prozesse, die Salenta Code gestartet hat (Baum), mit CPU
            let ps = Proc.zsh("ps -axo pid=,ppid=,%cpu=,rss=,etime=,command=", in: NSTemporaryDirectory(), timeout: 20).out
            var rows: [(pid: Int32, ppid: Int32, cpu: Double, rss: Int, etime: String, cmd: String)] = []
            for line in ps.split(separator: "\n") {
                let f = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true).map(String.init)
                guard f.count == 6, let pid = Int32(f[0]), let ppid = Int32(f[1]) else { continue }
                rows.append((pid, ppid, Double(f[2]) ?? 0, Int(f[3]) ?? 0, f[4], f[5]))
            }
            var tree: Set<Int32> = [me]
            var grew = true
            while grew {
                grew = false
                for r in rows where !tree.contains(r.pid) && tree.contains(r.ppid) { tree.insert(r.pid); grew = true }
            }
            // tmux-Sitzungen gehören auch dazu (laufen unter dem tmux-Server)
            for r in rows where r.cmd.contains("aos-") && r.cmd.contains("tmux") { tree.insert(r.pid) }
            grew = true
            while grew {
                grew = false
                for r in rows where !tree.contains(r.pid) && tree.contains(r.ppid) { tree.insert(r.pid); grew = true }
            }
            let mine = rows.filter { tree.contains($0.pid) }.sorted { $0.cpu > $1.cpu }
            let total = mine.reduce(0) { $0 + $1.cpu }
            out += String(format: "Alles von Salenta Code gestartet: %d Prozesse, %.0f %% CPU, %d MB\n", mine.count, total, mine.reduce(0) { $0 + $1.rss } / 1024)
            for r in mine.prefix(25) {
                out += String(format: "  %6.1f %%  %5d MB  %8@  %@\n", r.cpu, r.rss / 1024, r.etime as NSString, String(r.cmd.prefix(140)) as NSString)
            }

            // 3. die größten Verbraucher am ganzen Mac (Energie-Wirkung)
            let top = Proc.zsh("top -l 2 -s 3 -o cpu -n 12 -stats pid,command,cpu,mem,threads,idlew,power", in: NSTemporaryDirectory(), timeout: 30).out
            if let r = top.range(of: "PID", options: .backwards) {
                out += "\nGanzer Mac (top, 3 s):\n" + String(top[r.lowerBound...])
            }

            // 4. wo der Hauptthread seine Zeit verbringt
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("aos-perf-sample.txt")
            _ = Proc.zsh("/usr/bin/sample \(me) 3 -file \(Shell.quote(tmp.path))", in: NSTemporaryDirectory(), timeout: 30)
            if let s = try? String(contentsOf: tmp, encoding: .utf8) {
                out += "\nThreads (sample 3 s) – die beschäftigtsten mit ihren eigenen Funktionen:\n" + threads(s)
                try? s.write(to: Paths.root.appendingPathComponent("logs/perf-sample.txt"), atomically: true, encoding: .utf8)
                if Paths.isDevBuild { try? s.write(to: Paths.source.appendingPathComponent("logs/perf-sample.txt"), atomically: true, encoding: .utf8) }
                try? FileManager.default.removeItem(at: tmp)
            }

            // 5. Speicherdruck (Auslagern macht den ganzen Mac zäh) und GPU-Last durch lokale Modelle
            let vm = Proc.zsh("memory_pressure -Q 2>/dev/null | tail -1; sysctl -n hw.memsize; vm_stat | egrep 'Pages (free|active|wired down|occupied by compressor)|Swapouts'; sysctl vm.swapusage; (pgrep -x ollama >/dev/null && (ollama ps 2>/dev/null || true))", in: NSTemporaryDirectory(), timeout: 20).out
            out += "\nSpeicher und lokale Modelle:\n" + vm

            let url = Paths.root.appendingPathComponent("logs/perf.txt")
            try? out.write(to: url, atomically: true, encoding: .utf8)
            // Entwickler-Build: zusätzlich in den Quellordner (dort liest die Analyse mit)
            if Paths.source != Paths.root {
                try? FileManager.default.createDirectory(at: Paths.source.appendingPathComponent("logs"), withIntermediateDirectories: true)
                try? out.write(to: Paths.source.appendingPathComponent("logs/perf.txt"), atomically: true, encoding: .utf8)
            }
            DispatchQueue.main.async { running = false; completion?(url) }
        }
    }

    /// Benutzer- und System-CPU-Zeit dieses Prozesses in Sekunden.
    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }

    /// Je Thread: wie viele Stichproben er NICHT geschlafen hat, und die eigenen Funktionen darin.
    static func threads(_ s: String) -> String {
        var groups: [(head: String, n: Int, lines: [String])] = []
        for raw in s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("    "), !raw.hasPrefix("    +"), t.contains("Thread_"), let n = Int(t.split(separator: " ").first ?? "") {
                groups.append((t, n, []))
            } else if !groups.isEmpty, raw.hasPrefix("    +") {
                groups[groups.count - 1].lines.append(t)
            }
        }
        var out: [String] = []
        for g in groups {
            let own = g.lines.filter { $0.contains("(in SalentaOS)") || $0.contains("(in SwiftTerm)") }
            guard !own.isEmpty else { continue }
            let short = own.prefix(6).map { l -> String in
                let x = l.trimmingCharacters(in: CharacterSet(charactersIn: " +!:|"))
                return "      " + String(x.prefix(150))
            }
            out.append("  \(g.head.prefix(110))\n" + short.joined(separator: "\n"))
        }
        return out.prefix(10).joined(separator: "\n") + "\n"
    }

    /// Aus einem sample-Bericht: Zeilen mit eigenen und SwiftUI-Funktionen auf dem Hauptthread, nach Häufigkeit.
    static func summarize(_ s: String) -> String {
        guard let start = s.range(of: "Main Thread") else { return "  (kein Hauptthread gefunden)\n" }
        let main = s[start.lowerBound...].prefix(400_000)
        var counts: [String: Int] = [:]
        let re = try? NSRegularExpression(pattern: #"^\s*[+!:| ]*(\d+)\s+(.+?)\s+\(in ([^)]+)\)"#, options: [.anchorsMatchLines])
        let text = String(main)
        re?.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { m, _, _ in
            guard let m, let nr = Range(m.range(at: 1), in: text), let fr = Range(m.range(at: 2), in: text), let lr = Range(m.range(at: 3), in: text) else { return }
            let lib = String(text[lr])
            guard lib == "SalentaOS" || lib == "SwiftUI" || lib == "SwiftTerm" || lib == "AttributeGraph" else { return }
            let fn = String(text[fr].prefix(110))
            counts["\(lib): \(fn)", default: 0] = max(counts["\(lib): \(fn)", default: 0], Int(text[nr]) ?? 0)
        }
        return counts.sorted { $0.value > $1.value }.prefix(30).map { "  \($0.value)\t\($0.key)" }.joined(separator: "\n") + "\n"
    }
}
