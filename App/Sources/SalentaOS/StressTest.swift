import AgenticOSKit
import Foundation

// Volllast-Test (nur Entwickler-Build): lastet alle Kerne 90 s lang voll aus und protokolliert alle 5 s,
// wie Salenta Code reagiert – Wärme, CPU, erlaubte Helfer und wie schnell die Oberfläche noch antwortet.
// Die Last-Prozesse laufen mit niedrigster Priorität und werden in jedem Fall wieder beendet. Ergebnis: logs/stress.txt.

enum StressTest {
    static var running = false

    static func run(seconds: Int = 90, completion: ((URL) -> Void)? = nil) {
        guard !running else { return }
        running = true
        DispatchQueue.global(qos: .utility).async {
            let cores = ProcessInfo.processInfo.activeProcessorCount
            var procs: [Process] = []
            for _ in 0..<cores {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                if (try? p.run()) != nil { setpriority(PRIO_PROCESS, id_t(p.processIdentifier), 20); procs.append(p) }
            }
            defer { procs.forEach { if $0.isRunning { $0.terminate() } } }
            var out = "Salenta Code – Volllast-Test \(DateCoding.stamp(Date()))\n"
            out += "\(procs.count) Last-Prozesse auf \(cores) Kernen, \(seconds) s\n\n"
            out += "  s   CPU   Wärme      Helfer  Oberfläche\n"
            var worstUI = 0.0, hottest = ProcessInfo.ThermalState.nominal, minCap = 4
            let start = Date()
            while Date().timeIntervalSince(start) < Double(seconds) {
                Thread.sleep(forTimeInterval: 5)
                let t0 = Date(), sem = DispatchSemaphore(value: 0)
                var cpu = 0.0, cap = 0
                DispatchQueue.main.async { cpu = SystemLoad.shared.cpu; cap = PowerProfile.capParallel(4); sem.signal() }
                let answered = sem.wait(timeout: .now() + 3) == .success
                let ui = Date().timeIntervalSince(t0) * 1000
                let th = ProcessInfo.processInfo.thermalState
                if th.rawValue > hottest.rawValue { hottest = th }
                worstUI = max(worstUI, answered ? ui : 3000)
                minCap = min(minCap, cap)
                let name: String = { switch th { case .nominal: "ok"; case .fair: "warm"; case .serious: "heiß"; case .critical: "kritisch"; @unknown default: "?" } }()
                out += String(format: "%3d  %3.0f %%  %-9@  %d/4     %@\n", Int(Date().timeIntervalSince(start)), cpu, name as NSString, cap,
                              (answered ? String(format: "%.0f ms", ui) : "hängt (>3 s)") as NSString)
            }
            procs.forEach { if $0.isRunning { $0.terminate() } }
            out += String(format: "\nErgebnis: Oberfläche antwortete spätestens nach %.0f ms, höchste Wärmestufe %d, weniger Helfer erlaubt: %@\n",
                          worstUI, hottest.rawValue, (minCap < 4 ? "ja (\(minCap)/4)" : "nein") as NSString)
            out += worstUI < 500 ? "✓ Oberfläche bleibt unter Volllast flüssig\n" : "✗ Oberfläche stockt unter Volllast\n"
            let url = Paths.source.appendingPathComponent("logs/stress.txt")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? out.write(to: url, atomically: true, encoding: .utf8)
            DispatchQueue.main.async { running = false; completion?(url) }
        }
    }
}
