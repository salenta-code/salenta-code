import AgenticOSKit
import AppKit
import AVFoundation
import Speech
import SwiftUI

// Spracheingabe wie in der Claude-App: Mikrofon antippen → Aufnahme-Leiste mit Wellenform und Zeit,
// live mitgeschrieben (Apple-Spracherkennung), beim Fertig-Haken schärft Whisper (large-v3-turbo, lokal) nach,
// dann steht der Text im Feld. X oder Esc bricht ab.

final class Dictation: ObservableObject {
    static let shared = Dictation()

    enum Phase: Equatable { case idle, recording, transcribing }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var partial = ""
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 48)
    @Published private(set) var started: Date?
    @Published var error: String?
    @Published var errorIsPermission = false

    var active: Bool { phase == .recording }
    var polishing: Bool { phase == .transcribing }

    private let engine = AVAudioEngine()
    private let audioQ = DispatchQueue(label: "dictation.audio")
    private var wavFile: AVAudioFile?
    private var wavURL: URL?
    private var wavFrames: AVAudioFramePosition = 0
    private var converter: AVAudioConverter?
    private var completion: ((String) -> Void)?
    private var sfRequest: SFSpeechAudioBufferRecognitionRequest?
    private var sfTask: SFSpeechRecognitionTask?
    private var cancelled = false

    static var engineName: String {
        whisperReady && useWhisper ? L("Live: Apple Spracherkennung · Ergebnis: Whisper large-v3-turbo (lokal)") : L("Apple Spracherkennung")
    }

    var locale: Locale { Locale(identifier: Profile.languageCode == "de" ? "de-DE" : "en-US") }

    // MARK: Whisper

    static var whisperModel: URL { Paths.support.appendingPathComponent("whisper/ggml-large-v3-turbo.bin") }
    static var whisperCLI: String? {
        ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? Detection.which("whisper-cli")
    }
    static var whisperReady: Bool { whisperCLI != nil && FileManager.default.fileExists(atPath: whisperModel.path) }
    static var useWhisper: Bool { UserDefaults.standard.object(forKey: "dictation.whisper") as? Bool ?? true }

    static func installWhisper(log: URL) {
        let dir = whisperModel.deletingLastPathComponent().path
        let cmd = "(command -v whisper-cli >/dev/null || brew install whisper-cpp) && mkdir -p \(Shell.quote(dir)) && "
            + "curl -L --fail -o \(Shell.quote(whisperModel.path + ".part")) https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin && "
            + "mv \(Shell.quote(whisperModel.path + ".part")) \(Shell.quote(whisperModel.path)) && echo FERTIG"
        Shell.spawn(cmd, log: log)
    }

    static func log(_ s: String) {
        let url = Paths.root.appendingPathComponent("logs/dictation.log")
        let line = "\(Date()) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    // MARK: Start / Fertig / Abbrechen

    func toggle(completion: @escaping (String) -> Void) {
        switch phase {
        case .idle: start(completion: completion)
        case .recording: finish()
        case .transcribing: break
        }
    }

    func start(completion: @escaping (String) -> Void) {
        guard phase == .idle else { return }
        self.completion = completion
        error = nil
        errorIsPermission = false
        partial = ""
        cancelled = false
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        Self.log("start · mic=\(mic.rawValue) speech=\(SFSpeechRecognizer.authorizationStatus().rawValue) whisper=\(Self.whisperReady)")
        let go = {
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    Self.log("speech auth \(status.rawValue)")
                    if status != .authorized && !Self.whisperReady {
                        self.fail(L("Spracherkennung nicht erlaubt – Systemeinstellungen › Datenschutz & Sicherheit › Spracherkennung › Salenta Code"), permission: true)
                        return
                    }
                    self.begin(live: status == .authorized)
                }
            }
        }
        if mic == .authorized { go(); return }
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async {
                Self.log("mic access \(ok)")
                if ok { go() } else { self.fail(L("Kein Mikrofon-Zugriff – Systemeinstellungen › Datenschutz & Sicherheit › Mikrofon › Salenta Code einschalten"), permission: true) }
            }
        }
    }

    private func fail(_ msg: String, permission: Bool = false) {
        Self.log("error: \(msg)")
        error = msg
        errorIsPermission = permission
        phase = .idle
    }

    private func begin(live: Bool) {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        Self.log("input format \(format)")
        guard format.sampleRate > 0, format.channelCount > 0 else { fail(L("Kein Mikrofon gefunden (oder kein Zugriff)"), permission: true); return }

        // Aufnahme für Whisper: 16 kHz, mono, 16 Bit
        let wavFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aos-dictation-\(UUID().uuidString.prefix(6)).wav")
        wavURL = url
        wavFrames = 0
        do {
            wavFile = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                                                                  AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                                                  AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false],
                                      commonFormat: .pcmFormatInt16, interleaved: true)
        } catch { Self.log("wav open failed \(error)") }
        converter = AVAudioConverter(from: format, to: wavFormat)

        if live {
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.addsPunctuation = true
            req.taskHint = .dictation
            req.contextualStrings = ["Claude Code", "Codex", "Cursor", "Junie", "Supabase", "Shopify", "Repo", "Commit", "Pull Request", "Salenta"]
            sfRequest = req
            let rec = SFSpeechRecognizer(locale: locale)
            if rec?.isAvailable != true { Self.log("SFSpeechRecognizer not available for \(locale.identifier)") }
            sfTask = rec?.recognitionTask(with: req) { [weak self] result, err in
                if let err { Self.log("live error \(err.localizedDescription)") }
                guard let result else { return }
                DispatchQueue.main.async { self?.partial = result.bestTranscription.formattedString }
            }
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.sfRequest?.append(buffer)
            self.audioQ.async { self.writeWav(buffer, to: wavFormat) }
            let n = Int(buffer.frameLength)
            if let ch = buffer.floatChannelData?[0], n > 0 {
                var sum: Float = 0
                for i in stride(from: 0, to: n, by: 4) { sum += ch[i] * ch[i] }
                let rms = sqrt(sum / Float(max(n / 4, 1)))
                let lvl = min(1, pow(rms * 20, 0.7))
                DispatchQueue.main.async {
                    self.levels.removeFirst()
                    self.levels.append(lvl)
                }
            }
        }
        engine.prepare()
        do { try engine.start() } catch { fail(error.localizedDescription); return }
        started = Date()
        phase = .recording
        NSSound(named: "Tink")?.play()
        Self.log("recording")
    }

    private func writeWav(_ buffer: AVAudioPCMBuffer, to fmt: AVAudioFormat) {
        guard let converter, let wavFile else { return }
        let ratio = fmt.sampleRate / buffer.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64) else { return }
        var fed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, s in
            if fed { s.pointee = .noDataNow; return nil }
            fed = true
            s.pointee = .haveData
            return buffer
        }
        if status != .error, err == nil, out.frameLength > 0 {
            do { try wavFile.write(from: out); wavFrames += AVAudioFramePosition(out.frameLength) }
            catch { Self.log("wav write \(error)") }
        }
    }

    private func stopAudio() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        sfRequest?.endAudio()
        levels = Array(repeating: 0, count: levels.count)
    }

    /// Abbrechen – nichts wird eingefügt.
    func cancel() {
        guard phase == .recording else { return }
        cancelled = true
        stopAudio()
        sfTask?.cancel()
        sfTask = nil; sfRequest = nil
        audioQ.async { self.wavFile = nil; if let u = self.wavURL { try? FileManager.default.removeItem(at: u) } }
        partial = ""
        phase = .idle
        Self.log("cancelled")
    }

    /// Fertig – Text übernehmen (mit Whisper nachgeschärft, falls installiert).
    func finish() {
        guard phase == .recording else { return }
        stopAudio()
        phase = .transcribing
        NSSound(named: "Pop")?.play()
        let url = wavURL
        audioQ.async {
            self.wavFile = nil   // Datei schließen
            let frames = self.wavFrames
            Self.log("finish · wav frames \(frames)")
            // Live-Erkennung kurz ausklingen lassen
            Thread.sleep(forTimeInterval: 0.7)
            var text: String?
            if Self.useWhisper, Self.whisperReady, let url, frames > 8000 {
                text = Self.whisper(url, language: Profile.languageCode)
                Self.log("whisper → \(text?.count ?? -1) Zeichen")
            }
            if let url { try? FileManager.default.removeItem(at: url) }
            DispatchQueue.main.async {
                self.sfTask?.finish()
                self.sfTask = nil; self.sfRequest = nil
                let live = self.partial.trimmingCharacters(in: .whitespacesAndNewlines)
                let result = (text?.isEmpty == false ? text! : live)
                Self.log("result live=\(live.count) final=\(result.count)")
                self.partial = ""
                self.phase = .idle
                if result.isEmpty {
                    self.error = frames < 8000 ? L("Nichts aufgenommen – ist das richtige Mikrofon gewählt?") : L("Nichts erkannt – bitte nochmal sprechen")
                    self.errorIsPermission = false
                } else {
                    self.completion?(result)
                }
            }
        }
    }

    static func whisper(_ wav: URL, language: String) -> String? {
        guard let cli = whisperCLI else { return nil }
        let prompt = language == "de"
            ? "Auftrag an einen KI-Coding-Agent. Claude Code, Codex, Cursor, Repo, Commit, Pull Request, Supabase, Shopify, Salenta."
            : "Task for an AI coding agent. Claude Code, Codex, Cursor, repo, commit, pull request."
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["-m", whisperModel.path, "-l", language, "-nt", "-np", "--prompt", prompt, "-f", wav.path]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { log("whisper start failed \(error)"); return nil }
        var data = Data(), errData = Data()
        let done = DispatchSemaphore(value: 0), errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { data = out.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); errDone.signal() }
        if done.wait(timeout: .now() + 90) == .timedOut { p.terminate(); log("whisper timeout"); return nil }
        _ = errDone.wait(timeout: .now() + 5)
        while p.isRunning { usleep(20_000) }  // kein waitUntilExit: das dreht den RunLoop und kann SwiftUI mitten im Zeichnen abstürzen lassen
        if p.terminationStatus != 0 {
            log("whisper exit \(p.terminationStatus): " + String(decoding: errData.suffix(600), as: UTF8.self))
            return nil
        }
        let text = String(decoding: data, as: UTF8.self).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") && !$0.hasPrefix("whisper_") }
            .joined(separator: " ")
        // Whisper-Halluzinationen bei Stille
        let junk = ["Untertitel im Auftrag des ZDF", "Untertitelung des ZDF", "Vielen Dank fürs Zuschauen", "Thank you for watching", "[Musik]"]
        if junk.contains(where: { text.contains($0) }) && text.count < 80 { return "" }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Oberfläche (wie in der Claude-App)

/// Mikrofon-Knopf: antippen = Aufnahme starten, während der Aufnahme erscheint die Aufnahme-Leiste.
struct MicButton: View {
    @ObservedObject private var d = Dictation.shared
    let onText: (String) -> Void

    var body: some View {
        Button { d.toggle(completion: onText) } label: {
            Group {
                if d.polishing { ProgressView().controlSize(.small) }
                else { Image(systemName: d.active ? "checkmark" : "mic").font(.body.weight(.semibold)) }
            }
            .foregroundStyle(d.active ? Color.white : .secondary)
            .frame(width: 30, height: 30)
            .background(Circle().fill(d.active ? Color.accentColor : Color.clear))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("d", modifiers: [.command, .option])
        .help(d.active ? L("Fertig – Text übernehmen (⌥⌘D)") : L("Diktieren (⌥⌘D)"))
    }
}

/// Aufnahme-Leiste: Abbrechen · Wellenform · Zeit · Fertig – darunter die Live-Mitschrift.
struct DictationStrip: View {
    @ObservedObject private var d = Dictation.shared

    var body: some View {
        if d.active || d.polishing {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: Grid.s) {
                    Button { d.cancel() } label: {
                        Image(systemName: "xmark").font(.caption.weight(.bold)).frame(width: 26, height: 26)
                            .background(Circle().fill(Color.secondary.opacity(0.15)))
                    }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction).help(L("Abbrechen (Esc)")).disabled(d.polishing)

                    if d.polishing {
                        ProgressView().controlSize(.small)
                        Text(Dictation.whisperReady && Dictation.useWhisper ? L("Transkribiere …") : L("Fertig …")).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    } else {
                        HStack(alignment: .center, spacing: 2) {
                            ForEach(Array(d.levels.enumerated()), id: \.offset) { _, l in
                                Capsule().fill(Color.primary.opacity(0.75)).frame(width: 3, height: max(3, CGFloat(l) * 26))
                            }
                        }
                        .frame(height: 28)
                        .frame(maxWidth: .infinity)
                        .animation(.linear(duration: 0.08), value: d.levels)
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(elapsed).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Button { d.finish() } label: {
                            Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white).frame(width: 26, height: 26)
                                .background(Circle().fill(Color.accentColor))
                        }
                        .buttonStyle(.plain).keyboardShortcut(.return, modifiers: []).help(L("Fertig (↩)"))
                    }
                }
                if !d.partial.isEmpty {
                    Text(d.partial).font(.callout).foregroundStyle(.secondary).lineLimit(3).transition(.opacity)
                }
            }
            .padding(Grid.s)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
        } else if let e = d.error {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(e).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if d.errorIsPermission {
                    Button(L("Einstellungen öffnen")) {
                        let pane = e.contains("Mikrofon") ? "Privacy_Microphone" : "Privacy_SpeechRecognition"
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(u) }
                    }.font(.caption)
                }
                Button { d.error = nil } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain).help(L("Hinweis schließen"))
            }
        }
    }

    private var elapsed: String {
        let s = Int(Date().timeIntervalSince(d.started ?? Date()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension View {
    /// Spracheingabe für jedes Textfeld: Mikrofon unten rechts im Feld, Diktat wird angehängt.
    func dictation(_ text: Binding<String>, alignment: Alignment = .bottomTrailing) -> some View {
        overlay(alignment: alignment) {
            MicButton { t in
                let cur = text.wrappedValue
                text.wrappedValue = cur + (cur.isEmpty || cur.hasSuffix(" ") || cur.hasSuffix("\n") ? "" : " ") + t
            }
            .padding(2)
        }
    }
}

/// Aufnahme-Leiste schwebend unten im Fenster – damit du auch außerhalb des Auftragsfelds siehst, dass zugehört wird.
struct FloatingDictationStrip: View {
    @ObservedObject private var d = Dictation.shared
    var body: some View {
        if d.active || d.polishing {
            DictationStrip()
                .padding(Grid.m)
                .frame(maxWidth: 560)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .padding(.bottom, Grid.xl)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
