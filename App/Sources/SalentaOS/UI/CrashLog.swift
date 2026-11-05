import Darwin
import Foundation

/// Schreibt bei einem Absturz den Stacktrace nach logs/crash.log (nur für die eigene Fehlersuche).
enum CrashLog {
    private static var fd: Int32 = -1

    static func install() {
        let path = Paths.root.appendingPathComponent("logs/crash.log").path
        fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        let start = "\n=== Start \(Date()) ===\n"
        _ = start.withCString { write(fd, $0, strlen($0)) }
        NSSetUncaughtExceptionHandler { e in
            let msg = "Exception: \(e.name.rawValue) \(e.reason ?? "")\n\(e.callStackSymbols.joined(separator: "\n"))\n"
            _ = msg.withCString { write(CrashLog.fd, $0, strlen($0)) }
        }
        for sig in [SIGTRAP, SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE] {
            signal(sig) { s in
                let header = "Signal \(s)\n"
                _ = header.withCString { write(CrashLog.fd, $0, strlen($0)) }
                var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
                let n = backtrace(&frames, 64)
                backtrace_symbols_fd(&frames, n, CrashLog.fd)
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    // MARK: Hänger und Berichte von macOS

    private static let pongLock = NSLock()
    private static var _lastPong = Date()
    private static var lastPong: Date {
        get { pongLock.lock(); defer { pongLock.unlock() }; return _lastPong }
        set { pongLock.lock(); _lastPong = newValue; pongLock.unlock() }
    }
    private static var hangReported = false

    /// Prüft alle 2 s, ob der Hauptthread antwortet. Hängt er > 8 s, wird mit `sample` festgehalten, wo er steht
    /// (logs/hang-….txt) – so lässt sich ein „eingefrorenes“ Fenster genau nachvollziehen.
    static func startWatchdog() {
        let t = Thread {
            var memTick = 0
            while true {
                Thread.sleep(forTimeInterval: 2)
                DispatchQueue.main.async { lastPong = Date(); if hangReported { hangReported = false; mark("Hauptthread antwortet wieder") } }
                let stuck = Date().timeIntervalSince(lastPong)
                if stuck > 8 && !hangReported {
                    hangReported = true
                    mark("HÄNGER: Hauptthread seit \(Int(stuck)) s blockiert – sample läuft")
                    let f = Paths.root.appendingPathComponent("logs/hang-\(Int(Date().timeIntervalSince1970)).txt").path
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                    p.arguments = [String(getpid()), "4", "-mayDie", "-file", f]
                    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                    try? p.run()
                }
                memTick += 1
                if memTick % 150 == 0 { mark("Speicher \(residentMB()) MB") }   // alle 5 min
            }
        }
        t.name = "salenta.watchdog"
        t.qualityOfService = .utility
        t.start()
    }

    static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
    }

    /// Kopiert die Absturz-/Hängerberichte, die macOS über Salenta Code geschrieben hat, nach logs/crashreports.
    static func collectSystemReports() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let src = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
            let dst = Paths.root.appendingPathComponent("logs/crashreports", isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            let recent = Date().addingTimeInterval(-3 * 86400)
            for f in files where f.lastPathComponent.hasPrefix("SalentaOS") {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                guard m > recent else { continue }
                try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
                let target = dst.appendingPathComponent(f.lastPathComponent)
                if !fm.fileExists(atPath: target.path) { try? fm.copyItem(at: f, to: target); mark("macOS-Bericht übernommen: \(f.lastPathComponent)") }
            }
        }
    }

    static func mark(_ text: String) {
        guard fd >= 0 else { return }
        let line = "· \(text)\n"
        _ = line.withCString { write(fd, $0, strlen($0)) }
    }
}
