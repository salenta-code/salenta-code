# Salenta Code (App)

Native macOS-App, SwiftUI, Swift-Package.
Swift-5-Sprachmodus, macOS 14+, eine Abhängigkeit: SwiftTerm 1.5.1 (Terminals).

## Bauen

```bash
./build.sh --open        # baut, installiert nach ~/Applications/Salenta Code.app, startet neu
```
Vollständiges Compiler-Log: `../logs/swift-build.log`.

## Aufbau

- `Sources/AgenticOSKit/` – Logik ohne UI: Aufgabenmodell (tolerantes JSON), Quick-Capture-Parser. Tests in `Tests/`.
- `Sources/SalentaOS/App.swift` – Fenster, Menüleiste, Befehle, globales Kürzel ⌃⌥Leertaste
- `Stores.swift` – TaskStore (data/tasks.json, Dateibeobachtung), PanelStore (data/panels.json)
- `Services.swift` – Kalender (EventKit), Apple Mail (osascript), CLI-Erkennung
- `Agents.swift` – Terminal-Sitzungen (SwiftTerm), Agent-Übergabe
- `Web.swift` – dauerhafte WKWebViews für Web-Apps, Popups, Downloads
- Views: `ContentView` (Navigation, ⌘K), `CockpitView`, `TasksView`, `AgentsView`, `ConnectorsView`, `SettingsView`
- `UI/Theme.swift` – 4-pt-Raster, Karten, Bereichsfarben
- `Setup.swift` – Einrichtung beim ersten Start, Einstellungen (Profil, Bereiche, Verbindungen, Mail)
- `OSAgent.swift`, `Router.swift`, `Conversations.swift` – eigener Agent, automatische Agent-Wahl, Aufträge als Chat
- Übersetzungen: `Resources/en.lproj/Localizable.strings` (Schlüssel = deutscher Quelltext). Neue Texte dort ergänzen.

## Regeln

- Native Mac-Optik: Systemfarben, SF Symbols, Bereichsfarben nur als Kennzeichnung.
- Abstände nur aus `Grid` (4-pt-Raster).
- Nach jeder Änderung `./build.sh --open` und alle Seiten ansehen.
