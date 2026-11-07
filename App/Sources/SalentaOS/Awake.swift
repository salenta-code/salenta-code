import AgenticOSKit
import AppKit
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import Network
import SwiftUI
import UserNotifications

// Wach bleiben: der Mac läuft weiter, auch zugeklappt – damit Agents über Nacht durcharbeiten.
//  • Sitzung mit Endzeit (Stunden, bis morgen früh, oder automatisch solange Agents arbeiten)
//  • Deckel zu: Bildschirm aus, Störer-Apps einfrieren (SIGSTOP), Ton aus, Stromsparmodus – Deckel auf: alles zurück
//  • Akku- und Hitzeregeln: Stromsparmodus unter 40 %, Ende unter 10 % oder bei kritischer Hitze
//  • Wiederherstellungs-Journal + launchd-Absicherung: stürzt die App ab, macht der Mac nach Ablauf trotzdem alles rückgängig
//  • Optional: bei WLAN-Ausfall aufs iPhone-Hotspot wechseln und Agents nach dem Ausfall mit „weiter“ anstupsen
// Zugeklappt wach bleiben braucht eine einmalige sudoers-Regel für vier pmset-Befehle (du richtest sie selbst im Terminal ein).

struct FrozenProc: Codable, Hashable {
    let pid: Int32
    let started: String   // Startzeit aus `ps -o lstart`, damit nie ein fremder Prozess mit gleicher PID fortgesetzt wird
    let name: String
}

struct AwakeJournal: Codable {
    var endEpoch: Double
    var startedEpoch: Double
    var auto: Bool
    var sleepDisabled = false
    var lowPowerByUs = false
    var mutedByUs = false
    var displayOff = false
    var frozen: [FrozenProc] = []
    var endDate: Date { Date(timeIntervalSince1970: endEpoch) }
}

final class Awake: ObservableObject {
    static let shared = Awake()

    @Published private(set) var journal: AwakeJournal?
    @Published private(set) var lidClosed = false
    @Published private(set) var lidModeReady = false
    @Published private(set) var backstopInstalled = false
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var onBattery = false
    @Published private(set) var lastEvent: String?
    @Published private(set) var tick = 0

    weak var agents: AgentManager?

    var active: Bool { journal != nil }
    var endAt: Date? { journal?.endDate }

    // Einstellungen
    static let sudoersFile = "/etc/sudoers.d/salenta-os"
    static let backstopLabel = "ai.salenta.os.awake"
    private let d = UserDefaults.standard
    func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
    func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) as? Int ?? def }
    var freezeList: [String] {
        (d.string(forKey: "awake.lid.freezeList") ?? "Slack, WhatsApp, Discord")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?
    private var autoTimer: Timer?
    private var lidCandidate: Bool?
    private var lastMinute = -1
    private var lowPowerReasons: Set<String> = []
    private var autoSince: Date?
    private var monitor: NWPathMonitor?
    private var offlineSince: Date?
    private var hotspotTried = false
    private let q = DispatchQueue(label: "salenta.awake")

    private var journalURL: URL { Paths.data.appendingPathComponent("awake.json") }
    private var logURL: URL { Paths.root.appendingPathComponent("logs/awake.log") }

    init() {
        if let data = try? Data(contentsOf: journalURL), let j = try? JSONDecoder().decode(AwakeJournal.self, from: data) {
            journal = j
        }
        lidClosed = Self.readClamshell() ?? false
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.boot() }
    }

    private func boot() {
        refreshSetupState()
        if let j = journal {
            if j.endDate > Date() {
                log("Sitzung nach Neustart der App fortgesetzt (bis \(j.endDate.formatted(date: .omitted, time: .shortened)))")
                takeAssertion()
                if j.sleepDisabled { q.async { _ = self.sudoPmset("-a disablesleep 1") } }
                startTimer()
            } else {
                log("Abgelaufene Sitzung gefunden – wird rückgängig gemacht")
                finish(reason: L("Sitzung war abgelaufen, alles zurückgesetzt"), sync: false)
            }
        }
        autoTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.autoCheck() }
        startNetworkMonitor()
    }

    func refreshSetupState() {
        lidModeReady = FileManager.default.fileExists(atPath: Self.sudoersFile)
        backstopInstalled = FileManager.default.fileExists(atPath: plistURL.path)
    }

    // MARK: Start / Verlängern / Ende

    func start(for seconds: TimeInterval, auto: Bool = false) {
        start(until: Date().addingTimeInterval(seconds), auto: auto)
    }

    func start(until end: Date, auto: Bool = false) {
        guard end > Date() else { return }
        if var j = journal {
            j.endEpoch = end.timeIntervalSince1970
            if !auto { j.auto = false }
            save(j)
            log("Endzeit geändert: \(end.formatted(date: .abbreviated, time: .shortened))")
            return
        }
        refreshSetupState()
        var j = AwakeJournal(endEpoch: end.timeIntervalSince1970, startedEpoch: Date().timeIntervalSince1970, auto: auto)
        j.sleepDisabled = lidModeReady   // erst ins Journal, dann ändern
        save(j)
        installBackstop()
        takeAssertion()
        lidClosed = Self.readClamshell() ?? false
        lidCandidate = nil
        startTimer()
        log((auto ? "Automatisch (Agents arbeiten) " : "") + "wach bis \(end.formatted(date: .abbreviated, time: .shortened))"
            + (lidModeReady ? " – auch zugeklappt" : " – nur aufgeklappt (Einrichtung für zugeklappt fehlt)"))
        if lidModeReady {
            q.async {
                let ok = self.sudoPmset("-a disablesleep 1")
                DispatchQueue.main.async {
                    if !ok, var j = self.journal {
                        j.sleepDisabled = false; self.save(j)
                        self.log("pmset disablesleep fehlgeschlagen – zugeklappt schläft der Mac. Einrichtung in den Einstellungen prüfen.")
                        self.notify(L("Zugeklappt wach bleiben klappt gerade nicht – sieh in den Einstellungen unter „Wach bleiben“ nach."))
                    }
                }
            }
        }
    }

    func extend(_ seconds: TimeInterval) {
        guard let j = journal else { start(for: seconds); return }
        start(until: max(j.endDate, Date()).addingTimeInterval(seconds))
    }

    func stop() { finish(reason: L("beendet"), sync: false) }

    /// Beim Beenden der App: synchron alles zurücksetzen.
    func stopForQuit() {
        guard journal != nil else { return }
        finish(reason: L("App beendet – alles zurückgesetzt"), sync: true)
    }

    private func finish(reason: String, sync: Bool) {
        guard let j = journal else { return }
        timer?.invalidate(); timer = nil
        releaseAssertion()
        lowPowerReasons = []
        autoSince = nil
        let work = {
            self.resumeFrozen(j.frozen)
            if j.mutedByUs { _ = Proc.zsh("/usr/bin/osascript -e 'set volume without output muted'", in: NSTemporaryDirectory(), timeout: 10) }
            if j.lowPowerByUs { _ = self.sudoPmset("-b lowpowermode 0") }
            if j.sleepDisabled { _ = self.sudoPmset("-a disablesleep 0") }
            if j.displayOff { Self.wakeDisplay() }
        }
        if sync { work() } else { q.async(execute: work) }
        try? FileManager.default.removeItem(at: journalURL)
        journal = nil
        log("Ende: \(reason)")
        if !sync { notify(L("Wach bleiben: ") + reason) }
    }

    // MARK: Takt (alle 5 s während einer Sitzung)

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.step() }
        step()
    }

    private func step() {
        guard let j = journal else { return }
        // Oberfläche nur neu zeichnen, wenn sich die angezeigte Minute ändert
        let minute = Int(j.endDate.timeIntervalSinceNow) / 60
        if minute != lastMinute { lastMinute = minute; tick += 1 }
        if Date() >= j.endDate { finish(reason: L("Zeit abgelaufen"), sync: false); return }

        // Deckel – erst nach zwei gleichen Messungen (≈ 5–10 s), damit kurzes Wackeln nichts auslöst
        if let now = Self.readClamshell(), now != lidClosed {
            if lidCandidate == now { lidCandidate = nil; lidClosed = now; lidChanged(closed: now) } else { lidCandidate = now }
        } else { lidCandidate = nil }

        // Akku
        let (pct, battery) = Self.readBattery()
        if batteryPercent != pct { batteryPercent = pct }
        if onBattery != battery { onBattery = battery }
        if battery, let pct {
            let endFloor = int("awake.battery.end", 10), lowFloor = int("awake.battery.low", 40)
            if endFloor > 0 && pct < endFloor { safetyStop = true; finish(reason: L("Akku unter ") + "\(endFloor) %", sync: false); return }
            setLowPower(pct < lowFloor, reason: "battery")
        } else { setLowPower(false, reason: "battery") }

        // Hitze
        if bool("awake.heat", true) {
            switch ProcessInfo.processInfo.thermalState {
            case .critical: safetyStop = true; finish(reason: L("Mac ist kritisch heiß"), sync: false); return
            case .serious: setLowPower(true, reason: "heat")
            default: setLowPower(false, reason: "heat")
            }
        }
    }

    // MARK: Deckel

    private func lidChanged(closed: Bool) {
        guard var j = journal else { return }
        if closed {
            log("Deckel zu")
            if bool("awake.lid.display", true) {
                j.displayOff = true; save(j)
                q.async { _ = Proc.zsh("/usr/bin/pmset displaysleepnow", in: NSTemporaryDirectory(), timeout: 10) }
            }
            if bool("awake.lid.freeze", true) { freezeApps() }
            if bool("awake.lid.mute", true) {
                q.async {
                    let r = Proc.zsh("/usr/bin/osascript -e 'output muted of (get volume settings)'", in: NSTemporaryDirectory(), timeout: 10)
                    guard r.out.contains("false") else { return }
                    DispatchQueue.main.async { if var j = self.journal { j.mutedByUs = true; self.save(j) } }
                    _ = Proc.zsh("/usr/bin/osascript -e 'set volume with output muted'", in: NSTemporaryDirectory(), timeout: 10)
                }
            }
            if bool("awake.lid.lowpower", true) { setLowPower(true, reason: "lid") }
        } else {
            log("Deckel auf")
            let frozen = j.frozen, muted = j.mutedByUs
            j.frozen = []; j.mutedByUs = false; j.displayOff = false
            save(j)
            setLowPower(false, reason: "lid")
            q.async {
                self.resumeFrozen(frozen)
                if muted { _ = Proc.zsh("/usr/bin/osascript -e 'set volume without output muted'", in: NSTemporaryDirectory(), timeout: 10) }
                Self.wakeDisplay()
            }
        }
    }

    /// Apps aus der Liste (Name oder Bundle-ID) samt Unterprozessen anhalten. Salenta Code, Terminals und Meeting-/Diktier-Apps nie.
    private func freezeApps() {
        let wanted = freezeList.map { $0.lowercased() }
        let never: Set<String> = ["ai.salenta.os", "ai.salenta.os.dev", "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "com.mitchellh.ghostty",
                                  "us.zoom.xos", "com.microsoft.teams2", "com.apple.facetime", "com.electron.wispr-flow", "com.obsproject.obs-studio"]
        let apps = NSWorkspace.shared.runningApplications.filter { a in
            let b = (a.bundleIdentifier ?? "").lowercased(), n = (a.localizedName ?? "").lowercased()
            return !never.contains(b) && a.processIdentifier != getpid() && (wanted.contains(b) || wanted.contains(n))
        }
        guard !apps.isEmpty else { return }
        q.async {
            let table = Self.processTable()
            var list: [FrozenProc] = []
            for a in apps {
                for pid in Self.tree(of: a.processIdentifier, in: table) {
                    guard let st = table[pid]?.started else { continue }
                    list.append(FrozenProc(pid: pid, started: st, name: a.localizedName ?? ""))
                }
            }
            // erst ins Journal, dann anhalten
            DispatchQueue.main.sync { if var j = self.journal { j.frozen += list; self.save(j) } }
            for p in list { kill(p.pid, SIGSTOP) }
            DispatchQueue.main.async { self.log("Eingefroren: " + Set(list.map(\.name)).sorted().joined(separator: ", ")) }
        }
    }

    /// Nur fortsetzen, was nachweislich von uns angehalten wurde (gleiche PID und gleiche Startzeit).
    private func resumeFrozen(_ list: [FrozenProc]) {
        guard !list.isEmpty else { return }
        let table = Self.processTable()
        for p in list where table[p.pid]?.started == p.started { kill(p.pid, SIGCONT) }
    }

    // MARK: Stromsparmodus

    private func setLowPower(_ on: Bool, reason: String) {
        guard lidModeReady else { return }
        let before = !lowPowerReasons.isEmpty
        if on { lowPowerReasons.insert(reason) } else { lowPowerReasons.remove(reason) }
        let after = !lowPowerReasons.isEmpty
        guard before != after, var j = journal else { return }
        if after {
            q.async {
                let already = Proc.zsh("/usr/bin/pmset -g | grep -i lowpowermode", in: NSTemporaryDirectory(), timeout: 10).out.contains("1")
                guard !already else { return }
                DispatchQueue.main.sync { if var j = self.journal { j.lowPowerByUs = true; self.save(j) } }
                if self.sudoPmset("-b lowpowermode 1") { DispatchQueue.main.async { self.log("Stromsparmodus an (\(reason))") } }
            }
        } else if j.lowPowerByUs {
            j.lowPowerByUs = false; save(j)
            q.async { _ = self.sudoPmset("-b lowpowermode 0") }
            log("Stromsparmodus aus")
        }
    }

    // MARK: Automatisch, solange Agents arbeiten

    /// Nach einem Sicherheits-Stopp (Akku leer, Hitze) darf die Automatik nicht sofort wieder einschalten –
    /// sonst läuft der Mac zugeklappt leer. Erst wieder, wenn Strom dran ist bzw. der Akku sich erholt hat.
    private var safetyStop = false

    private func autoCheck() {
        guard bool("awake.auto", false), !SafeStart.active else { autoSince = nil; return }
        if safetyStop {
            let (pct, battery) = Self.readBattery()
            let floor = int("awake.battery.end", 10)
            let cool = ProcessInfo.processInfo.thermalState != .critical && ProcessInfo.processInfo.thermalState != .serious
            if cool && (!battery || (pct ?? 0) >= floor + 15) { safetyStop = false; log("Automatik wieder frei (Strom/Akku ok)") }
            else { return }
        }
        let (nowPct, nowBattery) = Self.readBattery()
        if nowBattery, let p = nowPct, p < int("awake.battery.end", 10) + 5 { return }
        let busy = agents?.sessions.contains(where: \.running) ?? false
        let grace = TimeInterval(int("awake.auto.grace", 15) * 60)
        let maxHours = int("awake.auto.max", 12)
        guard busy else { if !active { autoSince = nil }; return }   // nichts mehr los: die laufende Sitzung endet von selbst nach der Nachlaufzeit
        if autoSince == nil { autoSince = Date() }
        if let s = autoSince, Date().timeIntervalSince(s) > TimeInterval(maxHours * 3600) {
            if autoSince != .distantPast { log("Automatik: Höchstdauer \(maxHours) h erreicht – keine Verlängerung mehr") }
            autoSince = .distantPast
            return
        }
        let target = Date().addingTimeInterval(grace)
        if let j = journal {
            if j.endDate < target { var nj = j; nj.endEpoch = target.timeIntervalSince1970; save(nj) }
        } else {
            start(until: target, auto: true)
        }
    }

    // MARK: Netz: Hotspot-Wechsel und Agents anstupsen

    private func startNetworkMonitor() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.pathChanged(online: path.status == .satisfied) }
        }
        m.start(queue: DispatchQueue(label: "salenta.awake.net"))
        monitor = m
    }

    private func pathChanged(online: Bool) {
        if !online {
            if offlineSince == nil { offlineSince = Date() }
            hotspotTried = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.maybeJoinHotspot() }
            return
        }
        guard let since = offlineSince else { return }
        offlineSince = nil
        let outage = Date().timeIntervalSince(since)
        guard active, outage >= 90, bool("awake.nudge", false) else { return }
        let enter = bool("awake.nudge.enter", true)
        let word = d.string(forKey: "awake.nudge.text").flatMap { $0.isEmpty ? nil : $0 } ?? "continue"
        let ids = agents?.sessions.filter { $0.running && $0.persistent }.map(\.id) ?? []
        for id in ids { Persist.sendKeys(id, word, enter: enter) }
        if !ids.isEmpty { log("Netz nach \(Int(outage)) s wieder da – \(ids.count) Agent(s) mit „\(word)“ angestupst") }
    }

    private func maybeJoinHotspot() {
        guard active, let since = offlineSince, Date().timeIntervalSince(since) >= 30, !hotspotTried else { return }
        let ssid = (d.string(forKey: "awake.hotspot.ssid") ?? "").trimmingCharacters(in: .whitespaces)
        guard !ssid.isEmpty, Secrets.has("hotspot") else { return }
        hotspotTried = true
        log("Kein Netz seit 30 s – verbinde mit Hotspot „\(ssid)“")
        q.async {
            let ports = Proc.zsh("/usr/sbin/networksetup -listallhardwareports", in: NSTemporaryDirectory(), timeout: 10).out
            var dev = "en0"
            let lines = ports.components(separatedBy: "\n")
            if let i = lines.firstIndex(where: { $0.contains("Wi-Fi") || $0.contains("WLAN") || $0.contains("AirPort") }), i + 1 < lines.count,
               let r = lines[i + 1].range(of: "Device: ") { dev = String(lines[i + 1][r.upperBound...]).trimmingCharacters(in: .whitespaces) }
            let r = Proc.zsh("/usr/sbin/networksetup -setairportnetwork \(Shell.quote(dev)) \(Shell.quote(ssid)) \(Secrets.shellValue("hotspot"))",
                             in: NSTemporaryDirectory(), timeout: 40)
            DispatchQueue.main.async {
                self.log(r.code == 0 && !r.out.lowercased().contains("error") ? "Mit Hotspot verbunden" : "Hotspot-Verbindung fehlgeschlagen")
            }
        }
    }

    // MARK: launchd-Absicherung

    private var scriptURL: URL { Paths.support.appendingPathComponent("awake-backstop.zsh") }
    private var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(Self.backstopLabel).plist")
    }

    /// Läuft jede Minute. Ist die App weg und die Endzeit vorbei, macht das Skript alles aus dem Journal rückgängig.
    func installBackstop() {
        let j = journalURL.path, l = logURL.path
        let script = """
        #!/bin/zsh
        # Salenta Code – Absicherung für „Wach bleiben“. Wird von launchd jede Minute gestartet.
        J=\(Shell.quote(j))
        [ -f "$J" ] || exit 0
        /usr/bin/pgrep -xq SalentaOS && exit 0
        x() { /usr/bin/plutil -extract "$1" raw -o - "$J" 2>/dev/null }
        end=$(x endEpoch) || exit 0
        [ "${end%.*}" -gt "$(date +%s)" ] && exit 0
        i=0
        while pid=$(x frozen.$i.pid); do
          st=$(x frozen.$i.started)
          cur=$(/bin/ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//')
          [ -n "$cur" ] && [ "$cur" = "$st" ] && kill -CONT "$pid"
          i=$((i+1))
        done
        [ "$(x mutedByUs)" = "true" ] && /usr/bin/osascript -e 'set volume without output muted'
        [ "$(x lowPowerByUs)" = "true" ] && /usr/bin/sudo -n /usr/bin/pmset -b lowpowermode 0
        [ "$(x sleepDisabled)" = "true" ] && /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0
        mv "$J" "$J.recovered-$(date +%s)"
        echo "$(date '+%F %T') Absicherung: App war weg, Sitzung abgelaufen – alles zurückgesetzt" >> \(Shell.quote(l))
        """
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(Self.backstopLabel)</string>
          <key>ProgramArguments</key><array><string>/bin/zsh</string><string>\(scriptURL.path)</string></array>
          <key>StartInterval</key><integer>60</integer>
          <key>RunAtLoad</key><true/>
        </dict></plist>
        """
        let oldScript = try? String(contentsOf: scriptURL, encoding: .utf8)
        let oldPlist = try? String(contentsOf: plistURL, encoding: .utf8)
        guard oldScript != script || oldPlist != plist else { return }
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? plist.write(to: plistURL, atomically: true, encoding: .utf8)
        let p = Shell.quote(plistURL.path)
        q.async {
            _ = Proc.zsh("launchctl bootout gui/$(id -u)/\(Self.backstopLabel) 2>/dev/null; launchctl bootstrap gui/$(id -u) \(p)", in: NSTemporaryDirectory(), timeout: 15)
            DispatchQueue.main.async { self.refreshSetupState(); self.log("Absicherung (launchd) eingerichtet") }
        }
    }

    func removeBackstop() {
        let p = Shell.quote(plistURL.path)
        q.async {
            _ = Proc.zsh("launchctl bootout gui/$(id -u)/\(Self.backstopLabel) 2>/dev/null; rm -f \(p)", in: NSTemporaryDirectory(), timeout: 15)
            try? FileManager.default.removeItem(at: self.scriptURL)
            DispatchQueue.main.async { self.refreshSetupState() }
        }
    }

    // MARK: Einrichtung für zugeklappt (führst du selbst im Terminal aus – braucht dein Passwort)

    static var setupCommand: String {
        let rule = "%s ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -b lowpowermode 1, /usr/bin/pmset -b lowpowermode 0\\n"
        return "f=$(mktemp) && printf '\(rule)' \"$USER\" > \"$f\" && sudo /usr/sbin/visudo -cf \"$f\" && sudo /usr/bin/install -m 0440 -o root -g wheel \"$f\" \(sudoersFile) && rm -f \"$f\" && echo '✓ Fertig – Salenta Code kann den Mac jetzt auch zugeklappt wach halten. Fenster kann zu.'"
    }

    static var removeCommand: String {
        "sudo /usr/bin/pmset -a disablesleep 0; sudo rm -f \(sudoersFile) && echo '✓ Entfernt.'"
    }

    // MARK: Systemzugriff

    private func sudoPmset(_ args: String) -> Bool {
        Proc.zsh("/usr/bin/sudo -n /usr/bin/pmset \(args)", in: NSTemporaryDirectory(), timeout: 20).code == 0
    }

    private func takeAssertion() {
        guard assertion == 0 else { return }
        var id: IOPMAssertionID = 0
        let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn), "Salenta Code: wach bleiben" as CFString, &id)
        if r == kIOReturnSuccess { assertion = id }
    }

    private func releaseAssertion() {
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
    }

    static func wakeDisplay() {
        var id: IOPMAssertionID = 0
        if IOPMAssertionDeclareUserActivity("Salenta Code: Deckel auf" as CFString, kIOPMUserActiveLocal, &id) == kIOReturnSuccess {
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { IOPMAssertionRelease(id) }
        }
    }

    /// true = zugeklappt, false = offen, nil = kein Deckel (Desktop-Mac)
    static func readClamshell() -> Bool? {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard s != 0 else { return nil }
        defer { IOObjectRelease(s) }
        guard let v = IORegistryEntryCreateCFProperty(s, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
        return (v as? Bool) ?? (v as? NSNumber)?.boolValue
    }

    static func readBattery() -> (Int?, Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false) }
        for src in list {
            guard let desc = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = desc[kIOPSCurrentCapacityKey] as? Int ?? 0, mx = max(desc[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            let onBattery = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            return (cur * 100 / mx, onBattery)
        }
        return (nil, false)
    }

    /// pid → (Eltern-PID, Startzeit) für alle Prozesse
    static func processTable() -> [Int32: (ppid: Int32, started: String)] {
        let r = Proc.zsh("/bin/ps -axo pid=,ppid=,lstart=", in: NSTemporaryDirectory(), timeout: 15)
        var t: [Int32: (Int32, String)] = [:]
        for line in r.out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int32(parts[0]), let pp = Int32(parts[1]) else { continue }
            t[pid] = (pp, parts.dropFirst(2).joined(separator: " "))
        }
        return t.mapValues { (ppid: $0.0, started: $0.1) }
    }

    static func tree(of root: Int32, in table: [Int32: (ppid: Int32, started: String)]) -> [Int32] {
        var out = [root], i = 0
        while i < out.count {
            let p = out[i]
            out += table.filter { $0.value.ppid == p }.map(\.key).filter { !out.contains($0) }
            i += 1
        }
        return out
    }

    // MARK: Hilfen

    private func save(_ j: AwakeJournal) {
        journal = j
        if let data = try? JSONEncoder().encode(j) { try? data.write(to: journalURL, options: .atomic) }
    }

    func log(_ text: String) {
        lastEvent = text
        let line = "\(Date().formatted(.iso8601)) \(text)\n"
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
    }

    private func notify(_ text: String) {
        let c = UNMutableNotificationContent()
        c.title = "Salenta Code"; c.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        Notifier.push("Salenta Code", text, priority: 3, tags: "eye")
    }

    static func remaining(_ end: Date) -> String {
        let s = max(0, Int(end.timeIntervalSinceNow))
        let dd = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if dd > 0 { return "\(dd) T \(h) h" }
        return String(format: "%d:%02d", h, m)
    }
}

// MARK: - Oberfläche

/// Knopf in der Startseite und im Menüleisten-Fenster.
struct AwakeButton: View {
    @ObservedObject private var awake = Awake.shared
    @AppStorage("awake.auto") private var auto = false

    var body: some View {
        Menu {
            if let end = awake.endAt {
                Text(L("Wach bis ") + end.formatted(date: .abbreviated, time: .shortened))
                Button("+ 1 Stunde") { awake.extend(3600) }
                Button("+ 3 Stunden") { awake.extend(3 * 3600) }
                Button("Bis morgen 8 Uhr") { awake.start(until: Self.tomorrow8) }
                Divider()
                Button("Jetzt beenden", role: .destructive) { awake.stop() }
            } else {
                Button("1 Stunde") { awake.start(for: 3600) }
                Button("3 Stunden") { awake.start(for: 3 * 3600) }
                Button("8 Stunden") { awake.start(for: 8 * 3600) }
                Button("Bis morgen 8 Uhr") { awake.start(until: Self.tomorrow8) }
            }
            Divider()
            Toggle("Automatisch, solange Agents arbeiten", isOn: $auto)
            if !awake.lidModeReady {
                Divider()
                Button("Auch zugeklappt wach bleiben – einrichten …") { Detection.runInTerminal(Awake.setupCommand) }
            }
        } label: {
            Label(awake.endAt.map { L("Wach ") + Awake.remaining($0) } ?? (auto ? L("Wach: Auto") : L("Wach bleiben")),
                  systemImage: awake.active ? "eye.fill" : "eye")
                .font(.caption).foregroundStyle(awake.active ? Color.orange : .secondary)
                .monospacedDigit()
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(awake.active
              ? (awake.lidModeReady ? L("Mac bleibt wach – auch zugeklappt") : L("Mac bleibt wach, solange er aufgeklappt ist"))
              : L("Mac wach halten, damit Agents weiterarbeiten – auf Wunsch auch zugeklappt"))
    }

    static var tomorrow8: Date {
        let cal = Calendar.current
        let t = cal.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
        return t > Date() ? t : cal.date(byAdding: .day, value: 1, to: t) ?? t
    }
}

/// Menüleisten-Symbol: zeigt bei aktiver Sitzung ein Auge mit Restzeit.
struct AwakeMenuLabel: View {
    @ObservedObject private var awake = Awake.shared
    var body: some View {
        if let end = awake.endAt {
            Image(systemName: "eye.fill")
            Text(Awake.remaining(end)).monospacedDigit()
        } else {
            Image(nsImage: BrandImage.menuBar)
        }
        LoadMenuLabel()
    }
}

/// Einstellungen › Wach bleiben
struct AwakeSettings: View {
    @ObservedObject private var awake = Awake.shared
    @AppStorage("awake.auto") private var auto = false
    @AppStorage("awake.auto.grace") private var grace = 15
    @AppStorage("awake.auto.max") private var maxHours = 12
    @AppStorage("awake.lid.display") private var lidDisplay = true
    @AppStorage("awake.lid.freeze") private var lidFreeze = true
    @AppStorage("awake.lid.freezeList") private var freezeList = "Slack, WhatsApp, Discord"
    @AppStorage("awake.lid.mute") private var lidMute = true
    @AppStorage("awake.lid.lowpower") private var lidLowPower = true
    @AppStorage("awake.battery.low") private var batteryLow = 40
    @AppStorage("awake.battery.end") private var batteryEnd = 10
    @AppStorage("awake.heat") private var heat = true
    @AppStorage("awake.nudge") private var nudge = false
    @AppStorage("awake.nudge.enter") private var nudgeEnter = true
    @AppStorage("awake.nudge.text") private var nudgeText = "continue"
    @AppStorage("awake.hotspot.ssid") private var ssid = ""
    @State private var hotspotPW = ""
    @State private var hasHotspotPW = Secrets.has("hotspot")

    var body: some View {
        Form {
            Section("Status") {
                HStack {
                    Image(systemName: awake.active ? "eye.fill" : "eye").foregroundStyle(awake.active ? .orange : .secondary)
                    if let end = awake.endAt {
                        Text(L("Wach bis ") + end.formatted(date: .abbreviated, time: .shortened) + " (" + Awake.remaining(end) + ")")
                        Spacer()
                        Button("Beenden") { awake.stop() }
                    } else {
                        Text("Aus")
                        Spacer()
                        AwakeButton()
                    }
                }
                if let e = awake.lastEvent { Text(e).font(.caption).foregroundStyle(.secondary) }
                if let pct = awake.batteryPercent {
                    Text(L("Akku ") + "\(pct) %" + (awake.onBattery ? L(" – läuft auf Akku") : L(" – am Netzteil"))).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Automatisch") {
                Toggle("Wach bleiben, solange Agents arbeiten", isOn: $auto)
                Stepper(value: $grace, in: 5...120, step: 5) { Text(L("Nachlauf nach dem letzten Agent: ") + "\(grace) min") }
                Stepper(value: $maxHours, in: 1...72) { Text(L("Höchstens am Stück: ") + "\(maxHours) h") }
                Text("Sobald ein Agent läuft, hält Salenta Code den Mac wach und verlängert, solange gearbeitet wird. Ist alles fertig, endet die Sitzung nach dem Nachlauf von selbst.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Zugeklappt wach bleiben") {
                HStack {
                    Image(systemName: awake.lidModeReady ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(awake.lidModeReady ? .green : .secondary)
                    Text(awake.lidModeReady ? L("Eingerichtet") : L("Nicht eingerichtet – ohne das schläft der Mac beim Zuklappen ein"))
                    Spacer()
                    if awake.lidModeReady {
                        Button("Entfernen …") { Detection.runInTerminal(Awake.removeCommand) }
                    } else {
                        Button("Einrichten …") { Detection.runInTerminal(Awake.setupCommand) }.buttonStyle(.borderedProminent)
                    }
                    Button { awake.refreshSetupState() } label: { Image(systemName: "arrow.clockwise") }.help(L("Neu prüfen"))
                }
                Text("Öffnet das Terminal mit einem Befehl, der nach deinem Mac-Passwort fragt. Er legt /etc/sudoers.d/salenta-os an und erlaubt deinem Benutzer genau vier Befehle ohne Passwort: pmset disablesleep 0/1 und lowpowermode 0/1. Achtung: Das dürfen dann auch andere Programme, die unter deinem Benutzer laufen. Salenta Code speichert dein Passwort nie.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Nicht in einer geschlossenen Tasche benutzen – der Mac braucht Luft. Am besten am Netzteil, auf einer festen Unterlage. Zugeklappt ist das eingebaute Mikrofon aus (Hardware).")
                    .font(.caption).foregroundStyle(.orange)
            }
            Section("Beim Zuklappen") {
                Toggle("Bildschirm aus", isOn: $lidDisplay)
                Toggle("Apps einfrieren (pausieren, beim Aufklappen geht's weiter)", isOn: $lidFreeze)
                TextField("Apps (Namen oder Bundle-IDs, Komma-getrennt)", text: $freezeList).disabled(!lidFreeze)
                Toggle("Ton aus", isOn: $lidMute)
                Toggle("Stromsparmodus", isOn: $lidLowPower).disabled(!awake.lidModeReady)
                Text("Beim Aufklappen wird alles zurückgenommen. Eingefroren wird nur, was in der Liste steht – nie Salenta Code, Terminals oder Meeting-Apps. Fortgesetzt wird nur, was nachweislich von Salenta Code angehalten wurde.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Akku und Hitze") {
                Stepper(value: $batteryLow, in: 0...90, step: 5) { Text(L("Stromsparmodus unter ") + "\(batteryLow) %") }
                Stepper(value: $batteryEnd, in: 0...50, step: 5) { Text(batteryEnd == 0 ? L("Nie wegen Akku beenden") : L("Beenden unter ") + "\(batteryEnd) %") }
                Toggle("Bei starker Hitze Stromsparmodus, bei kritischer Hitze beenden", isOn: $heat)
                Text("Diese Regeln wirken, solange Salenta Code läuft. Stürzt die App ab, setzt eine Absicherung (launchd, jede Minute) nach Ablauf der Zeit alles zurück.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Image(systemName: awake.backstopInstalled ? "checkmark.shield.fill" : "shield").foregroundStyle(awake.backstopInstalled ? .green : .secondary)
                    Text(awake.backstopInstalled ? L("Absicherung aktiv") : L("Absicherung wird beim ersten Start eingerichtet"))
                    Spacer()
                    if awake.backstopInstalled && !awake.active { Button("Entfernen") { awake.removeBackstop() } }
                }
            }
            Section("Wenn das Netz weg ist") {
                TextField("iPhone-Hotspot (Name) – leer = aus", text: $ssid)
                HStack {
                    SecureField(hasHotspotPW ? L("Passwort gespeichert – zum Ändern neu eingeben") : L("Hotspot-Passwort"), text: $hotspotPW)
                    Button("Speichern") { Secrets.set("hotspot", hotspotPW); hotspotPW = ""; hasHotspotPW = true }.disabled(hotspotPW.isEmpty)
                }
                Text("Ist das WLAN während einer Sitzung 30 Sekunden weg, wechselt der Mac zum Hotspot. Das Passwort liegt nur im macOS-Schlüsselbund.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Agents nach einem Netzausfall anstupsen", isOn: $nudge)
                HStack {
                    TextField("Text", text: $nudgeText).frame(maxWidth: 160)
                    Toggle("mit Enter", isOn: $nudgeEnter)
                }.disabled(!nudge)
                Text("War das Netz mindestens 90 Sekunden weg, schreibt Salenta Code den Text in deine laufenden Agent-Sitzungen (nur die eigenen, im Hintergrund laufenden) – damit ein abgebrochener Agent weitermacht.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Protokoll: logs/awake.log")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .onAppear { awake.refreshSetupState() }
    }
}
