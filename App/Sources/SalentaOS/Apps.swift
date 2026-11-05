import AgenticOSKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Eintrag in der Seitenleiste: Web-App mit Symbol, Mac-App mit ihrem echten Icon.
struct AppLabel: View {
    let panel: WebPanel
    var body: some View {
        if let path = panel.app {
            Label {
                Text(panel.title)
            } icon: {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 16, height: 16)
            }
        } else {
            Label(panel.title, systemImage: panel.symbol)
        }
    }
}

/// App hinzufügen oder bearbeiten: Web-App (Adresse) oder Mac-App (aus /Programme).
struct AppEditor: View {
    @State var panel: WebPanel
    let onSave: (WebPanel) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var panels: PanelStore
    @State private var kind = 0

    private var isNew: Bool { panel.id.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.m) {
            Text(isNew ? "App hinzufügen" : "App bearbeiten").font(.headline)
            Picker("", selection: $kind) {
                Text("Web-App").tag(0)
                Text("Mac-App").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!isNew)

            Form {
                if kind == 0 {
                    TextField("Adresse", text: $panel.url, prompt: Text("https://…"))
                        .onSubmit(autoName)
                    TextField("Name", text: $panel.title, prompt: Text("z. B. Canva"))
                    Picker("Symbol", selection: $panel.symbol) {
                        ForEach(Self.symbols, id: \.self) { s in Label(s, systemImage: s).tag(s) }
                    }
                } else {
                    HStack {
                        if let path = panel.app {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 32, height: 32)
                            Text(panel.title)
                        } else {
                            Text("Keine App gewählt").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("App wählen …", action: chooseApp)
                    }
                }
                Picker("Gruppe", selection: $panel.group) {
                    ForEach(Array(Set(PanelStore.groups + panels.allGroups)).sorted(), id: \.self) { Text($0).tag($0) }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Hinzufügen" : "Sichern") {
                    autoName()
                    if panel.id.isEmpty { panel.id = "p-" + UUID().uuidString.prefix(6).lowercased() }
                    if kind == 0 { panel.app = nil }
                    onSave(panel)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(kind == 0 ? URL(string: panel.url)?.host == nil : panel.app == nil)
            }
        }
        .padding(Grid.l)
        .frame(width: 480)
        .onAppear { kind = panel.app == nil ? 0 : 1 }
    }

    private func autoName() {
        guard kind == 0 else { return }
        if !panel.url.lowercased().hasPrefix("http") { panel.url = "https://" + panel.url }
        if panel.title.trimmingCharacters(in: .whitespaces).isEmpty, let host = URL(string: panel.url)?.host {
            let parts = host.replacingOccurrences(of: "www.", with: "").replacingOccurrences(of: "app.", with: "").split(separator: ".")
            panel.title = (parts.first.map(String.init) ?? host).capitalized
        }
    }

    private func chooseApp() {
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowedContentTypes = [.application]
        p.prompt = "Hinzufügen"
        if p.runModal() == .OK, let u = p.url {
            panel.app = u.path
            panel.title = FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")
            panel.url = u.absoluteString
            panel.symbol = "app"
        }
    }

    static let symbols = ["globe", "sparkle", "bubble.left.and.bubble.right", "envelope", "calendar", "message", "phone",
                          "bag", "cart", "megaphone", "chart.bar", "doc.text", "folder", "photo", "video", "music.note",
                          "paintbrush", "hammer", "person.2", "building.2", "eurosign.circle", "shield.lefthalf.filled",
                          "bolt", "book", "map", "airplane", "heart", "star"]
}

/// Mac-App als Eintrag: Klick startet die App (einmal automatisch pro Start von Salenta Code).
struct MacAppPanelView: View {
    let panel: WebPanel
    let path: String
    static var opened: Set<String> = []

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(panel.title)
            } icon: {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 64, height: 64)
            }
        } description: {
            Text(FileManager.default.fileExists(atPath: path) ? "Läuft als eigene Mac-App." : "App nicht gefunden: \(path)")
        } actions: {
            Button { open() } label: { Label("Öffnen", systemImage: "arrow.up.forward.app") }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .navigationTitle(panel.title)
        .onAppear {
            if !Self.opened.contains(panel.id) { Self.opened.insert(panel.id); open() }
        }
    }

    private func open() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
    }
}
