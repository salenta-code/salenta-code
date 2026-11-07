import AgenticOSKit
import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ProfileSettings()
                .tabItem { Label("Profil", systemImage: "person.crop.circle") }
            AreaSettings()
                .tabItem { Label("Bereiche", systemImage: "square.grid.2x2") }
            ConnectionSettings()
                .tabItem { Label("Verbindungen", systemImage: "point.3.connected.trianglepath.dotted") }
            PanelSettings()
                .tabItem { Label("Apps", systemImage: "rectangle.stack") }
            MailSettings()
                .tabItem { Label("Mail", systemImage: "envelope") }
            ModelAccessSettings()
                .tabItem { Label("Modelle", systemImage: "cpu") }
            AwakeSettings()
                .tabItem { Label("Wach bleiben", systemImage: "eye") }
            PlanetPicker().padding(Grid.xl).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .tabItem { Label(L("Darstellung"), systemImage: "globe.europe.africa") }
            GeneralSettings()
                .tabItem { Label("Allgemein", systemImage: "gearshape") }
        }
        .frame(width: 720, height: 580)
    }
}

struct PanelSettings: View {
    @EnvironmentObject private var panels: PanelStore
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.m) {
            Text("Web-Apps in der Seitenleiste. Logins bleiben gespeichert. Gruppe frei wählbar.")
                .foregroundStyle(.secondary)
            List(selection: $selection) {
                ForEach($panels.panels) { $p in
                    HStack(spacing: Grid.s) {
                        Image(systemName: p.symbol).frame(width: 18)
                        TextField("Name", text: $p.title).frame(width: 130)
                        TextField("URL", text: $p.url)
                        TextField("Symbol", text: $p.symbol).frame(width: 110)
                        TextField("Gruppe", text: $p.group).frame(width: 110)
                    }
                    .textFieldStyle(.roundedBorder)
                    .tag(p.id)
                }
                .onMove { from, to in panels.panels.move(fromOffsets: from, toOffset: to) }
            }
            HStack {
                Button {
                    let id = "p-" + UUID().uuidString.prefix(6).lowercased()
                    panels.panels.append(WebPanel(id: id, title: "Neu", url: "https://", symbol: "globe", group: "Business"))
                    selection = id
                } label: { Image(systemName: "plus") }.help(L("App hinzufügen"))
                Button {
                    if let s = selection {
                        panels.panels.removeAll { $0.id == s }
                        WebPool.shared.forget(s)
                    }
                } label: { Image(systemName: "minus") }.help(L("Gewählte App entfernen"))
                .disabled(selection == nil)
                Spacer()
                Button("Standard wiederherstellen") { panels.resetToDefaults() }
                Button("Sichern") { panels.save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Grid.l)
        .onDisappear { panels.save() }
    }
}

struct GeneralSettings: View {
    @State private var root = Paths.root.path
    @State private var showRules = false

    var body: some View {
        Form {
            LabeledContent("Salenta-Code-Ordner") {
                HStack {
                    Text(root).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Button("Im Finder") { Launcher.reveal(Paths.tasks) }
                }
            }
            AppLanguagePicker()
            LabeledContent("Aufgaben-Datei", value: "data/tasks.json")
            LabeledContent("Globales Kürzel", value: "⌃⌥ Leertaste")
            LabeledContent("Befehlspalette", value: "⌘K")
            LabeledContent("Agents-CLI", value: "bin/aos list | add | done")
            Toggle("Erfolgsmomente zeigen (kleine Animation, wenn etwas geschafft ist)", isOn: Binding(
                get: { UserDefaults.standard.object(forKey: "celebrate.on") as? Bool ?? true },
                set: { UserDefaults.standard.set($0, forKey: "celebrate.on") }))
            Toggle("Mac-Auslastung in der Menüleiste zeigen", isOn: Binding(
                get: { UserDefaults.standard.object(forKey: "load.menubar") as? Bool ?? true },
                set: { UserDefaults.standard.set($0, forKey: "load.menubar") }))
            Picker("Schwere Prüfungen gleichzeitig (Typen, Tests, Build)", selection: Binding(
                get: { UserDefaults.standard.object(forKey: "load.checks") as? Int ?? 2 },
                set: { UserDefaults.standard.set($0, forKey: "load.checks") })) {
                Text("1 – schont den Mac").tag(1); Text("2").tag(2); Text("3").tag(3); Text("4 – schnell, wird heiß").tag(4)
            }
            .help("Am Akku, bei Hitze oder über 85 % Auslastung laufen Prüfungen immer nacheinander.")
            EnergySettings()
            Toggle("Fertige Aufträge automatisch abschließen (bleiben im Verlauf)", isOn: Binding(
                get: { UserDefaults.standard.object(forKey: "missions.autoClose") as? Bool ?? true },
                set: { UserDefaults.standard.set($0, forKey: "missions.autoClose") }))
            Toggle("Tipps & Tricks zeigen", isOn: Binding(
                get: { !UserDefaults.standard.bool(forKey: "tips.hidden") },
                set: { UserDefaults.standard.set(!$0, forKey: "tips.hidden") }))
            AgentConnections()
            EfficiencySettings()
            AgentCapabilities()
            Section("Agent- und Modellwahl") {
                Toggle("Beim Planen im Internet recherchieren (aktueller Stand, Trends, Empfehlungen zum Anhaken)", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: "research.onPlan") as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: "research.onPlan") }))
                Toggle("KI wählt Agent, Modell, Projekt und Skills (Claude Haiku, ein paar Sekunden)", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: "router.ai") as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: "router.ai") }))
                Toggle("Vor dem Start Vorschlag zeigen (Agent, Modell, Skills, Erweiterungen – bestätigen, ändern oder ablehnen)", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: "router.confirm") as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: "router.confirm") }))
                Text("Bei „Automatisch“ schaut Claude Haiku kurz auf den Auftrag und wählt den passenden Agent (Claude Code, Junie, Codex, OS-Agent), das Modell (Opus/Sonnet/Haiku bzw. Denktiefe bei Codex), das Repo und passende Skills. Ausgeschaltet entscheiden feste Stichwort-Regeln – sofort, aber ungenauer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Coding") {
                Toggle("Projekte automatisch aktuell halten (neue Commits von GitHub holen)", isOn: Binding(
                    get: { GitSync.autoPull },
                    set: { UserDefaults.standard.set($0, forKey: "projects.autoPull") }))
                Text("Holt alle 5 Minuten den neuesten Stand – nur wenn es gefahrlos geht: keine offenen Änderungen und keine eigenen, noch nicht hochgeladenen Commits.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Coding-Aufträge in eigener Arbeitskopie (git worktree)", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: "coding.worktree") as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: "coding.worktree") }))
                Text("Mehrere Agents können so gleichzeitig im selben Repo arbeiten. Am Ende: übernehmen, Pull Request oder verwerfen.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Sitzungen im Hintergrund weiterlaufen lassen (tmux) – auch wenn Salenta Code geschlossen ist", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: "sessions.persist") as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: "sessions.persist") }))
                Text(Persist.tmux == nil
                     ? "tmux fehlt – installieren mit: brew install tmux. Bis dahin setzt Salenta Code Sitzungen beim Start fort (Dialoge per --resume, Aufträge ab dem letzten Stand)."
                     : "Beim Start hängt sich Salenta Code automatisch wieder an alle laufenden Sitzungen an.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Prüfschleife") {
                Toggle("Nach jedem Coding-Auftrag automatisch bauen und testen", isOn: Binding(
                    get: { Verifier.autoRun }, set: { UserDefaults.standard.set($0, forKey: "verify.auto") }))
                Toggle("Zweites Modell prüft den Diff (Codex prüft Claude und umgekehrt)", isOn: Binding(
                    get: { Verifier.reviewOn }, set: { UserDefaults.standard.set($0, forKey: "verify.review") }))
                Toggle("Screenshot bei UI-Änderungen (Dev-Server + Chrome headless)", isOn: Binding(
                    get: { Verifier.screenshotOn }, set: { UserDefaults.standard.set($0, forKey: "verify.screenshot") }))
                Toggle("Bei roter Prüfung einmal automatisch nachbessern lassen", isOn: Binding(
                    get: { Verifier.autoFix }, set: { UserDefaults.standard.set($0, forKey: "verify.autofix") }))
                Text("Prüfbefehle erkennt Salenta Code selbst (swift, npm/pnpm/yarn, cargo, go, pytest, Shopify Theme Check). Eigene legst du pro Projekt unter Projekte › Schild-Symbol fest.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Regeln") {
                Button("Regeln für alle Projekte bearbeiten …") { showRules = true }
                Text("Text-Regeln gehen in jeden Auftrag. Blockier-Regeln (z. B. „nie ins veröffentlichte Theme pushen“) setzt die Freigabe hart durch – auch im Auto-Modus.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Spracheingabe") {
                Toggle("Nach dem Sprechen mit Whisper nachschärfen (beste Erkennung, läuft lokal)", isOn: Binding(
                    get: { Dictation.useWhisper }, set: { UserDefaults.standard.set($0, forKey: "dictation.whisper") }))
                HStack {
                    if Dictation.whisperReady {
                        Label("Whisper large-v3-turbo ist installiert", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Whisper installieren (~1,6 GB)") {
                            Dictation.installWhisper(log: Paths.root.appendingPathComponent("logs/whisper-install.log"))
                        }
                        Text("Lädt whisper.cpp per Homebrew und das Modell large-v3-turbo. Fortschritt: logs/whisper-install.log")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Live-Erkennung", value: Dictation.engineName)
                Text("Mikrofon-Knopf neben Senden oder ⌥⌘D: sprechen, nochmal drücken – der Text landet im Feld. Live schreibt Apples Spracherkennung mit (auf macOS 26+ das neue Modell).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            IntelligenceSettings()
            NotifySettings()
            WatchmanSettings()
            Section("Aufs Handy") {
                TextField("ntfy-Thema (z. B. salenta-deinname-7f3k) – leer = aus", text: Binding(
                    get: { UserDefaults.standard.string(forKey: "notify.ntfy") ?? "" }, set: { UserDefaults.standard.set($0, forKey: "notify.ntfy") }))
                HStack {
                    Button("Test senden") { Notifier.push("Salenta Code", L("Test – so kommen Freigaben und fertige Aufträge aufs Handy."), priority: 4) }
                        .disabled(Notifier.topic.isEmpty)
                    Text("App „ntfy“ (iOS/Android) installieren, dasselbe Thema abonnieren. Wähle ein langes, zufälliges Thema – wer es kennt, kann mitlesen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Fokus") {
                TextField("Wichtige Absender (Komma-getrennt) – deren Mails gelten immer als dringend", text: Binding(
                    get: { UserDefaults.standard.string(forKey: "focus.vips") ?? "" }, set: { UserDefaults.standard.set($0, forKey: "focus.vips") }))
            }
            AgentBrowserSettings()
            Section("Browser") {
                Toggle("Web-Apps als eigene Chrome-Fenster statt eingebettet", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: "web.chrome") as? Bool ?? false },
                    set: { UserDefaults.standard.set($0, forKey: "web.chrome") }))
                Text("Standard: alle Web-Apps laufen direkt im Salenta-Code-Fenster (einmal anmelden, Login bleibt). Links, Anmeldungen und „Beitreten“ öffnen in Chrome, falls installiert.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Berechtigungen") {
                Text("Kalender: Systemeinstellungen › Datenschutz & Sicherheit › Kalender. Mail: › Automation › Salenta Code › Mail.")
                    .foregroundStyle(.secondary)
                Button("Datenschutz-Einstellungen öffnen") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showRules) { RulesEditor(projectDir: nil) }
    }
}


/// Sprache der App: wie macOS, Deutsch oder Englisch. Gilt nach einem Neustart (macOS lädt die Texte beim Start).
struct AppLanguagePicker: View {
    // nur die eigene Einstellung der App zählt (nicht die Systemsprache)
    @State private var lang: String = ((UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String])?.first)
        .map { $0.hasPrefix("de") ? "de" : "en" } ?? ""

    var body: some View {
        Picker(L("Sprache"), selection: $lang) {
            Text(L("Wie macOS")).tag("")
            Text("Deutsch").tag("de")
            Text("English").tag("en")
        }
        .onChange(of: lang) { _, v in
            if v.isEmpty { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
            else { UserDefaults.standard.set([v], forKey: "AppleLanguages") }
            let a = NSAlert()
            a.messageText = L("Sprache geändert")
            a.informativeText = L("Salenta Code zeigt die neue Sprache nach einem Neustart.")
            a.addButton(withTitle: L("Jetzt neu starten")); a.addButton(withTitle: L("Später"))
            if a.runModal() == .alertFirstButtonReturn { Updater.relaunch(Bundle.main.bundleURL) }
        }
        .help(L("Sprache der Oberfläche und der Antworten deiner Agents"))
    }
}
