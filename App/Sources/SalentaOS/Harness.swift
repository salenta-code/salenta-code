import AgenticOSKit
import Foundation

// Salenta Harness anbinden: Schlüssel aus dem Schlüsselbund als Umgebungsvariablen (nie im Klartext in Dateien),
// Bereitschaft prüfen (Node + Schlüssel oder Ollama).
enum HarnessSetup {
    static var script: URL { Paths.root.appendingPathComponent("bin/salenta-harness") }

    static var hasKey: Bool { ["deepseek", "anthropic", "openai", "openrouter"].contains { Secrets.has($0) } }

    static var ready: Bool {
        FileManager.default.fileExists(atPath: script.path) && Detection.which("node") != nil && (hasKey || OllamaApp.installed)
    }

    static var status: String {
        if Detection.which("node") == nil { return L("Node.js fehlt – im Terminal: brew install node") }
        if !FileManager.default.fileExists(atPath: script.path) { return L("Salenta Harness fehlt im App-Paket – neu installieren") }
        if hasKey { return L("Bereit – nutzt den ersten eingetragenen Schlüssel (DeepSeek, Anthropic, OpenAI, OpenRouter)") }
        if OllamaApp.installed { return L("Bereit mit lokalem Modell (Ollama) – für bessere Ergebnisse einen Schlüssel eintragen") }
        return L("Noch kein Modell: Schlüssel eintragen oder Ollama einrichten")
    }

    static let keys = [("deepseek", "DEEPSEEK_API_KEY"), ("anthropic", "ANTHROPIC_API_KEY"), ("openai", "OPENAI_API_KEY"), ("openrouter", "OPENROUTER_API_KEY")]

    /// Shell-Exports für den Start. Die Schlüssel werden erst beim Start aus dem Schlüsselbund gelesen – unabhängig davon,
    /// ob die App sie schon nachgesehen hat (sonst fiel ein frisch gestarteter Lauf still auf das lokale Modell zurück).
    /// Nur wenn wirklich kein Schlüssel da ist, nimmt der Harness das lokale Modell.
    static func exports() -> String {
        var s = ""
        for (acc, env) in keys { s += "export \(env)=\(Secrets.shellValue(acc)); " }
        if let m = LocalFirst.shared.model {
            s += "if [ -z \"$DEEPSEEK_API_KEY$ANTHROPIC_API_KEY$OPENAI_API_KEY$OPENROUTER_API_KEY\" ]; then export SALENTA_HARNESS_PROVIDER=ollama SALENTA_HARNESS_MODEL=\(Shell.quote(m)); fi; "
        }
        return s
    }
}
