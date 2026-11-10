import AgenticOSKit
import Darwin
import IOKit
import IOKit.ps
import SwiftUI

// Wie stark arbeitet der Mac gerade? Gesamtauslastung, Anteil von Salenta Code und seinen Agents,
// lokales Modell, Wärme, Akku und Leistungsaufnahme – für die Menüleiste. Spart selbst Strom:
// CPU alle 5 s (ein Systemaufruf), Prozessliste alle 15 s.

final class SystemLoad: ObservableObject {
    static let shared = SystemLoad()

    @Published private(set) var cpu: Double = 0            // 0…100, ganzer Mac
    @Published private(set) var agentsCPU: Double = 0      // 0…100, Salenta Code + gestartete Agents/Prüfungen
    @Published private(set) var localCPU: Double = 0       // 0…100, lokales Modell (Ollama)
    @Published private(set) var top: [(name: String, cpu: Double)] = []
    @Published private(set) var thermal: ProcessInfo.ThermalState = .nominal
    @Published private(set) var battery: Int?
    @Published private(set) var onBattery = false
    @Published private(set) var watts: Double?
    @Published private(set) var peakToday: Double = 0
    @Published private(set) var hotMinutesToday = 0
    /// Freier Arbeitsspeicher in % (frei + inaktiv + spekulativ). Unter ~15 % lagert macOS aus – dann wird alles zäh.
    @Published private(set) var memFree: Double = 100

    private var last: (busy: UInt64, total: UInt64)?
    private var timer: Timer?
    private var tick = 0
    private let cores = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))
    private var day = Calendar.current.startOfDay(for: Date())

    var showInMenuBar: Bool { UserDefaults.standard.object(forKey: "load.menubar") as? Bool ?? true }

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.sample() }
        timer?.tolerance = 1
    }

    /// Wie viele schwere Prüfungen (Typen, Tests, Build) gleichzeitig laufen dürfen.
    var allowedChecks: Int {
        if thermal == .serious || thermal == .critical { return 1 }
        if onBattery { return 1 }
        if cpu > 85 || memFree < 15 { return 1 }
        return UserDefaults.standard.object(forKey: "load.checks") as? Int ?? 2
    }

    var isHot: Bool { thermal == .serious || thermal == .critical }

    private func sample() {
        guard Energy.due("load", every: 15) else { return }
        if let now = Self.ticks() {
            if let l = last, now.total > l.total {
                cpu = min(100, Double(now.busy - l.busy) / Double(now.total - l.total) * 100)
            }
            last = now
        }
        thermal = ProcessInfo.processInfo.thermalState
        if let m = Self.memoryFreePercent() { memFree = m }
        let today = Calendar.current.startOfDay(for: Date())
        if today != day { day = today; peakToday = 0; hotMinutesToday = 0 }
        peakToday = max(peakToday, cpu)
        tick += 1
        if isHot, tick % 12 == 0 { hotMinutesToday += 1 }
        // Lastprotokoll alle 5 Minuten (logs/load.log): zeigt im Effizienz-Bericht, ob Helfer den Mac auslasten oder heiß machen
        if tick % 20 == 1 || isHot && tick % 4 == 0 {
            let th: String = { switch thermal { case .nominal: "ok"; case .fair: "warm"; case .serious: "heiß"; case .critical: "kritisch"; @unknown default: "?" } }()
            let line = "\(ISO8601DateFormatter().string(from: Date())) cpu=\(Int(cpu))% agents=\(Int(agentsCPU))% local=\(Int(localCPU))% thermal=\(th)"
                + " mem=\(Int(memFree))%" + (onBattery ? " akku=\(battery ?? -1)%" : "") + (watts.map { String(format: " %.0fW", $0) } ?? "") + " cap=\(PowerProfile.capParallel(4))/4" + (cooled.isEmpty ? "" : " abkühlen=\(cooled.count)") + "\n"
            let url = Paths.root.appendingPathComponent("logs/load.log")
            DispatchQueue.global(qos: .utility).async {
                if let h = FileHandle(forWritingAtPath: url.path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                else { try? line.write(to: url, atomically: true, encoding: .utf8) }
                if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64), size > 400_000,
                   let text = try? String(contentsOf: url, encoding: .utf8) {
                    try? text.split(separator: "\n").suffix(2000).joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }
        if tick % 3 == 1 {
            DispatchQueue.global(qos: .utility).async {
                let p = Self.processTree()
                let (pct, batt) = Awake.readBattery()
                let w = Self.power(onBattery: batt)
                DispatchQueue.main.async {
                    self.agentsCPU = p.agents / self.cores
                    self.localCPU = p.local / self.cores
                    self.top = p.top.map { ($0.name, $0.cpu / self.cores) }
                    self.battery = pct
                    self.onBattery = batt
                    self.watts = w
                    self.coolDown(p.helpers, hot: self.thermal != .nominal)
                }
            }
        }
    }

    static func memoryFreePercent() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return nil }
        let page = Double(vm_kernel_page_size)
        let free = Double(UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.speculative_count)) * page
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return total > 0 ? min(100, free / total * 100) : nil
    }

    private static func ticks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return nil }
        let u = UInt64(info.cpu_ticks.0), s = UInt64(info.cpu_ticks.1), i = UInt64(info.cpu_ticks.2), n = UInt64(info.cpu_ticks.3)
        return (u + s + n, u + s + n + i)
    }

    /// Prozesse: Anteil von Salenta Code samt Kindern (auch Hintergrund-Sitzungen), lokales Modell, größte Verbraucher.
    static func processes() -> (agents: Double, local: Double, top: [(name: String, cpu: Double)]) {
        let r = processTree(); return (r.agents, r.local, r.top)
    }

    /// Wie `processes()`, plus die Prozess-IDs aller Helfer (Kinder von Salenta Code und seinen Hintergrund-Sitzungen).
    static func processTree() -> (agents: Double, local: Double, top: [(name: String, cpu: Double)], helpers: [Int32]) {
        // direkt /bin/ps statt einer Login-Shell – spart bei jedem Durchgang Strom
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,pcpu=,comm="]
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (0, 0, [], []) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        var rows: [Int32: (ppid: Int32, cpu: Double, name: String)] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let pp = Int32(parts[1]), let c = Double(parts[2]) else { continue }
            rows[pid] = (pp, c, (String(parts[3]) as NSString).lastPathComponent)
        }
        var children: [Int32: [Int32]] = [:]
        for (pid, v) in rows { children[v.ppid, default: []].append(pid) }
        var helpers: [Int32] = []
        func sum(_ root: Int32) -> Double {
            var total = 0.0, stack = [root], seen = Set<Int32>()
            while let p = stack.popLast() {
                guard seen.insert(p).inserted else { continue }
                total += rows[p]?.cpu ?? 0
                if p != root { helpers.append(p) }
                stack += children[p] ?? []
            }
            return total
        }
        let me = getpid()
        var agents = sum(me)
        for (pid, v) in rows where v.name == "tmux" && v.ppid == 1 { agents += sum(pid) - v.cpu }   // Hintergrund-Sitzungen
        let local = rows.values.filter { $0.name.hasPrefix("ollama") || $0.name == "llama-server" }.reduce(0) { $0 + $1.cpu }
        var byName: [String: Double] = [:]
        for v in rows.values { byName[v.name, default: 0] += v.cpu }
        let top = byName.sorted { $0.value > $1.value }.prefix(4).filter { $0.value >= 5 }.map { (name: $0.key, cpu: $0.value) }
        return (agents, local, top, helpers)
    }

    // MARK: Abkühlen
    // Wird der Mac warm, laufen die Helfer-Prozesse (Tests, Builds, Agents) auf den Effizienzkernen weiter
    // (macOS „Hintergrund“-Priorität). Die Arbeit geht weiter, nur langsamer – der Mac kühlt ab und bleibt bedienbar.
    private(set) var cooled = Set<Int32>()
    private func coolDown(_ helpers: [Int32], hot: Bool) {
        let now = Set(helpers)
        cooled = cooled.intersection(now)   // beendete Prozesse vergessen
        let todo = hot ? Array(now.subtracting(cooled)) : Array(cooled)
        guard !todo.isEmpty else { return }
        if hot { cooled.formUnion(todo) } else { cooled.removeAll() }
        DispatchQueue.global(qos: .utility).async {
            for pid in todo {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/taskpolicy")
                p.arguments = [hot ? "-b" : "-B", "-p", String(pid)]
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                try? p.run(); p.waitUntilExit()
            }
        }
        if hot { CrashLog.mark("Abkühlen: \(todo.count) Helfer-Prozesse auf Effizienzkerne (\(thermal == .fair ? "warm" : "heiß"))") }
    }

    /// Leistungsaufnahme in Watt (ungefähr). Am Netzteil: was hineingeht, am Akku: was entnommen wird.
    static func power(onBattery: Bool) -> Double? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return nil }
        if !onBattery, let t = d["PowerTelemetryData"] as? [String: Any], let mw = (t["SystemPowerIn"] as? NSNumber)?.doubleValue, mw > 0 {
            return mw / 1000
        }
        guard let v = (d["Voltage"] as? NSNumber)?.doubleValue,
              let a = ((d["InstantAmperage"] ?? d["Amperage"]) as? NSNumber)?.intValue else { return nil }
        let w = abs(Double(Int16(truncatingIfNeeded: a))) * v / 1_000_000
        return w > 0.1 ? w : nil
    }

    static func color(_ pct: Double) -> Color { pct >= 85 ? .red : pct >= 60 ? .orange : .green }

    var thermalText: String {
        switch thermal {
        case .nominal: L("kühl")
        case .fair: L("warm")
        case .serious: L("heiß – macOS bremst")
        case .critical: L("sehr heiß – stark gebremst")
        @unknown default: "–"
        }
    }
}

/// Höchstens so viele schwere Prüfungen gleichzeitig, wie der Mac gerade verträgt.
enum CheckGate {
    private static let lock = NSLock()
    private static var inFlight = 0

    /// Blockiert (Hintergrund-Thread) bis ein Platz frei ist; gibt false zurück, wenn abgebrochen.
    static func enter(cancelled: () -> Bool) -> Bool {
        while true {
            if cancelled() { return false }
            let allowed = max(1, SystemLoad.shared.allowedChecks)
            lock.lock()
            if inFlight < allowed { inFlight += 1; lock.unlock(); return true }
            lock.unlock()
            Thread.sleep(forTimeInterval: 2)
        }
    }

    static func leave() { lock.lock(); inFlight = max(0, inFlight - 1); lock.unlock() }
}

/// Kleine Anzeige neben dem Symbol in der Menüleiste.
struct LoadMenuLabel: View {
    @ObservedObject private var load = SystemLoad.shared
    @AppStorage("load.menubar") private var show = true
    var body: some View {
        Group {
            if show { Text(load.isHot ? "🔥\(Int(load.cpu))%" : "\(Int(load.cpu))%").monospacedDigit() }
        }
        .onAppear { load.start() }
    }
}

/// Abschnitt im Menüleisten-Fenster.
struct LoadSection: View {
    @ObservedObject private var load = SystemLoad.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(L("Mac-Auslastung"), systemImage: "gauge.with.dots.needle.67percent").font(.callout.weight(.semibold))
                Spacer()
                Text("\(Int(load.cpu)) %").font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(SystemLoad.color(load.cpu))
            }
            ProgressView(value: min(load.cpu, 100), total: 100).tint(SystemLoad.color(load.cpu))
            HStack(spacing: Grid.m) {
                stat("sparkle", String(format: "%.0f %%", load.agentsCPU), L("Salenta Code und seine Agents/Prüfungen"))
                if load.localCPU >= 1 { stat("desktopcomputer", String(format: "%.0f %%", load.localCPU), L("Lokales Modell (Ollama)")) }
                stat(load.isHot ? "flame.fill" : "thermometer.medium", load.thermalText, L("Wärme laut macOS"))
                    .foregroundStyle(load.isHot ? .red : load.thermal == .fair ? .orange : .secondary)
                if let b = load.battery {
                    stat(load.onBattery ? "battery.50" : "powerplug", "\(b) %", load.onBattery ? L("Akku") : L("Am Netzteil"))
                }
                if let w = load.watts { stat("bolt", String(format: "%.0f W", w), load.onBattery ? L("Verbrauch aus dem Akku") : L("Leistung aus dem Netzteil (inkl. Laden)")) }
            }
            .font(.caption).foregroundStyle(.secondary)
            if !load.top.isEmpty {
                Text(L("Größte Verbraucher: ") + load.top.map { "\($0.name) \(Int($0.cpu)) %" }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
            if let r = Energy.reason {
                Label(L("Energiesparen aktiv: ") + r, systemImage: "leaf.fill").font(.caption).foregroundStyle(.green)
            }
            Text(String(format: L("Spitze heute: %d %%"), Int(load.peakToday))
                 + (load.hotMinutesToday > 0 ? " · " + String(format: L("%d min heiß"), load.hotMinutesToday) : "")
                 + (load.allowedChecks == 1 ? " · " + L("Prüfungen laufen nacheinander") : ""))
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func stat(_ icon: String, _ text: String, _ help: String) -> some View {
        Label(text, systemImage: icon).help(help)
    }
}

// MARK: - Energiesparen

/// Unterwegs am Akku (oder bei Stromsparmodus/Hitze) arbeitet Salenta Code sparsam:
/// Hintergrund-Takte seltener, Prüfungen nacheinander, kein lokales Modell, der Betreuer startet nichts Neues.
enum Energy {
    static let d = UserDefaults.standard
    /// auto (Standard): sparen am Akku · always: immer sparen · off: nie
    static var mode: String { d.string(forKey: "energy.mode") ?? "auto" }
    /// Dürfen am Akku neue Aufträge vom Projekt-Betreuer und aus der Nachtschicht starten? Standard nein.
    static var agentsOnBattery: Bool { d.object(forKey: "energy.agentsOnBattery") as? Bool ?? false }

    static var onBattery: Bool { Awake.readBattery().1 }

    static var saving: Bool {
        switch mode {
        case "always": return true
        case "off": return false
        default:
            let l = SystemLoad.shared
            return l.onBattery || ProcessInfo.processInfo.isLowPowerModeEnabled || l.isHot
        }
    }

    /// Grund fürs Sparen – für Hinweise in der Oberfläche.
    static var reason: String? {
        guard saving else { return nil }
        if mode == "always" { return L("Energiesparen ist dauerhaft an") }
        if SystemLoad.shared.isHot { return L("Mac ist heiß") }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return L("Stromsparmodus") }
        return L("Mac läuft am Akku")
    }

    /// Dürfen Hintergrund-Agents (Betreuer, Nachtschicht) gerade neue Aufträge starten?
    static var backgroundAgentsOK: Bool { !saving || agentsOnBattery || mode == "off" }

    private static var lastRun: [String: Date] = [:]
    private static let lock = NSLock()

    /// Takt drosseln: Beim Sparen läuft die Aufgabe höchstens alle `every` Sekunden, sonst bei jedem Takt.
    static func due(_ key: String, every: TimeInterval) -> Bool {
        guard saving else { return true }
        lock.lock(); defer { lock.unlock() }
        if let l = lastRun[key], Date().timeIntervalSince(l) < every { return false }
        lastRun[key] = Date()
        return true
    }
}

/// Einstellungen › Energie
struct EnergySettings: View {
    @AppStorage("energy.mode") private var mode = "auto"
    @AppStorage("energy.agentsOnBattery") private var agentsOnBattery = false
    @ObservedObject private var load = SystemLoad.shared

    var body: some View {
        Section("Energie & Akku") {
            Picker("Energiesparen", selection: $mode) {
                Text("Automatisch – am Akku, im Stromsparmodus und bei Hitze").tag("auto")
                Text("Immer").tag("always")
                Text("Nie (volle Leistung, auch am Akku)").tag("off")
            }
            PowerProfileSettings()
            Toggle("Projekt-Betreuer und Nachtschicht dürfen am Akku neue Aufträge starten", isOn: $agentsOnBattery)
            Text("Beim Energiesparen: Hintergrund-Abfragen laufen seltener, Prüfungen nacheinander und mit niedriger Priorität, kein lokales Modell (Ollama braucht sehr viel Strom), und Betreuer und Nachtschicht starten nichts Neues, bis der Mac wieder am Netzteil hängt. Was du selbst startest, läuft immer.")
                .font(.caption).foregroundStyle(.secondary)
            if let r = Energy.reason {
                Label(L("Gerade aktiv: ") + r, systemImage: "leaf.fill").foregroundStyle(.green).font(.callout)
            }
        }
    }
}

// MARK: - Leistungsprofil der Agents

/// Wie viel vom Mac die Agents nutzen dürfen. Auf Apple-Chips entscheidet die Dienstgüte (QoS), ob ein Prozess auf den
/// sparsamen Effizienz-Kernen oder den heißen Leistungs-Kernen läuft – das spart viel mehr Strom als „nice“.
enum PowerProfile {
    /// eco · balanced (Standard) · full
    static var mode: String { UserDefaults.standard.string(forKey: "power.profile") ?? "balanced" }
    static var effective: String { Energy.saving && mode != "full" ? "eco" : mode }

    /// Vorsatz für Agent- und Prüfprozesse (taskpolicy) – leer bei voller Leistung.
    static var taskpolicyArgs: [String] {
        switch effective {
        case "eco": return ["-b"]                 // Hintergrund: Effizienz-Kerne, gedrosselte Festplatte
        case "full": return []
        default: return ["-c", "utility"]         // Ausgewogen: bevorzugt Effizienz-Kerne, kaum langsamer
        }
    }
    static var shellPrefix: String {
        let a = taskpolicyArgs
        return a.isEmpty || !FileManager.default.isExecutableFile(atPath: "/usr/sbin/taskpolicy") ? "" : "/usr/sbin/taskpolicy " + a.joined(separator: " ") + " "
    }
    /// Höchstzahl gleichzeitiger Helfer des Betreuers in diesem Profil
    /// Wie viele Helfer gleichzeitig laufen dürfen – passt sich der Lage an: heiß oder ausgelastet → weniger, nie mehr als eingestellt.
    /// Laufende Helfer werden nie abgebrochen; es startet nur nichts Neues, bis der Mac wieder Luft hat.
    static func capParallel(_ n: Int) -> Int {
        let load = SystemLoad.shared
        return cap(n, eco: effective == "eco", thermal: ProcessInfo.processInfo.thermalState, onBattery: load.onBattery, cpu: load.cpu, memFree: load.memFree)
    }

    /// Reine Regel (testbar): wie viele Helfer bei dieser Lage gleichzeitig laufen dürfen.
    static func cap(_ n: Int, eco: Bool, thermal: ProcessInfo.ThermalState, onBattery: Bool, cpu: Double, memFree: Double) -> Int {
        var cap = eco ? min(n, 1) : n
        switch thermal {
        case .critical: cap = 0
        case .serious: cap = min(cap, 1)
        case .fair: cap = min(cap, max(1, (n + 1) / 2))
        default: break
        }
        if onBattery { cap = min(cap, max(1, n / 2)) }
        if cpu > 85 { cap = min(cap, 1) }
        // Arbeitsspeicher knapp (lokales Modell, große Builds): keine weiteren Helfer – sonst lagert macOS aus und alles hängt
        if memFree < 15 { cap = min(cap, 1) }
        if memFree < 7 { cap = 0 }
        return cap
    }

    /// Suche der Agents (ripgrep) ohne Abhängigkeiten, Build-Ordner und große Dateien – spart Gigabytes an Lesezugriffen.
    static var ripgrepConfig: URL {
        let url = Paths.support.appendingPathComponent("ripgreprc")
        let content = """
        --glob=!node_modules/
        --glob=!**/node_modules/**
        --glob=!.git/
        --glob=!dist/
        --glob=!build/
        --glob=!.next/
        --glob=!.nuxt/
        --glob=!.turbo/
        --glob=!.vercel/
        --glob=!coverage/
        --glob=!.build/
        --glob=!DerivedData/
        --glob=!Pods/
        --glob=!*.tgz
        --glob=!*.zip
        --glob=!*.min.js
        --glob=!*.map
        --max-filesize=2M

        """
        if (try? String(contentsOf: url, encoding: .utf8)) != content { try? content.write(to: url, atomically: true, encoding: .utf8) }
        return url
    }
}

/// Einstellungen › Energie & Akku: Leistungsprofil
struct PowerProfileSettings: View {
    @AppStorage("power.profile") private var profile = "balanced"
    var body: some View {
        Picker("Leistung der Agents", selection: $profile) {
            Text("Sparsam – kühl und leise, etwas langsamer").tag("eco")
            Text("Ausgewogen (empfohlen)").tag("balanced")
            Text("Volle Leistung – schnell, wird warm").tag("full")
        }
        Text("Ausgewogen: Agents und Prüfungen laufen bevorzugt auf den sparsamen Kernen deines Mac und mit niedriger Priorität – du merkst beim Arbeiten nichts, der Mac bleibt deutlich kühler. Sparsam: zusätzlich nur ein Helfer gleichzeitig. Am Akku gilt automatisch „Sparsam“.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
