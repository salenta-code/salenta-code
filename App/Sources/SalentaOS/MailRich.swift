import AgenticOSKit
import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// Vollwertige Mail: HTML-Ansicht wie in Apple Mail (mit eingebetteten Bildern), Anhänge mit Vorschau,
// Sichern und „an Auftrag geben“, Senden und Weiterleiten mit Anhängen.
// Die Mails kommen weiter aus Apple Mail (alle Konten); Salenta Code liest die Rohdaten (MIME) und zerlegt sie selbst.

// MARK: - MIME

struct MailAttachment: Identifiable, Hashable {
    let id = UUID()
    let filename: String
    let contentType: String
    let data: Data
    let contentID: String?
    let inline: Bool
    var isImage: Bool { contentType.lowercased().hasPrefix("image/") }
    var size: String { ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file) }
}

struct ParsedMail {
    var html: String?
    var text: String?
    var attachments: [MailAttachment] = []
}

enum MIME {
    static func parse(_ raw: String) -> ParsedMail {
        var out = ParsedMail()
        walk(raw.replacingOccurrences(of: "\r\n", with: "\n"), into: &out)
        // eingebettete Bilder (cid:) direkt ins HTML – und dann nicht zusätzlich als Anhang zeigen
        if var h = out.html {
            var used = Set<UUID>()
            for a in out.attachments where a.contentID != nil {
                let cid = a.contentID!.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
                guard h.contains("cid:" + cid) else { continue }
                h = h.replacingOccurrences(of: "cid:" + cid, with: "data:\(a.contentType);base64," + a.data.base64EncodedString())
                used.insert(a.id)
            }
            out.html = h
            out.attachments.removeAll { used.contains($0.id) }
        }
        return out
    }

    private static func split(_ part: String) -> (headers: [String: String], body: String) {
        let r = part.range(of: "\n\n") ?? part.range(of: "\n")
        let headText = r.map { String(part[..<$0.lowerBound]) } ?? part
        let body = r.map { String(part[$0.upperBound...]) } ?? ""
        var headers: [String: String] = [:]
        var last: String?
        for line in headText.components(separatedBy: "\n") {
            if line.first == " " || line.first == "\t", let l = last {
                headers[l, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let c = line.firstIndex(of: ":") {
                let k = line[..<c].lowercased().trimmingCharacters(in: .whitespaces)
                headers[k] = String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
                last = k
            }
        }
        return (headers, body)
    }

    /// Wert und Parameter eines Headers: text/html; charset="utf-8"
    static func params(_ h: String?) -> (value: String, params: [String: String]) {
        guard let h else { return ("", [:]) }
        var parts = h.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let v = parts.isEmpty ? "" : parts.removeFirst().lowercased()
        var p: [String: String] = [:]
        for x in parts {
            guard let eq = x.firstIndex(of: "=") else { continue }
            var k = x[..<eq].lowercased().trimmingCharacters(in: .whitespaces)
            var val = String(x[x.index(after: eq)...]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if k.hasSuffix("*") {   // RFC 2231: utf-8''name
                k.removeLast()
                if let q = val.range(of: "''") { val = String(val[q.upperBound...]).removingPercentEncoding ?? val }
            }
            p[k] = decodeWords(val)
        }
        return (v, p)
    }

    private static func walk(_ part: String, into out: inout ParsedMail) {
        let (h, body) = split(part)
        let (type, tp) = params(h["content-type"] ?? "text/plain")
        if type.hasPrefix("multipart/"), let b = tp["boundary"] {
            for sub in body.components(separatedBy: "--" + b).dropFirst() {
                if sub.hasPrefix("--") { break }
                walk(String(sub.drop(while: { $0 == "\n" })), into: &out)
            }
            return
        }
        let enc = (h["content-transfer-encoding"] ?? "").lowercased()
        let (disp, dp) = params(h["content-disposition"])
        let name = dp["filename"] ?? tp["name"]
        let data = decode(body, encoding: enc)
        let isAttachment = disp == "attachment" || (name != nil && !(type.hasPrefix("text/") && disp != "attachment"))
        if !isAttachment && type == "text/html" && out.html == nil {
            out.html = text(data, charset: tp["charset"], encoding: enc, raw: body)
        } else if !isAttachment && type == "text/plain" && out.text == nil {
            out.text = text(data, charset: tp["charset"], encoding: enc, raw: body)
        } else if type == "message/rfc822" {
            walk(body, into: &out)
        } else if !type.hasPrefix("multipart/") {
            let cid = h["content-id"]
            let fname = name ?? (type.hasPrefix("image/") ? "Bild." + (type.components(separatedBy: "/").last ?? "png") : "Anhang")
            out.attachments.append(MailAttachment(filename: fname, contentType: type, data: data, contentID: cid, inline: disp != "attachment"))
        }
    }

    private static func decode(_ body: String, encoding: String) -> Data {
        switch encoding {
        case "base64":
            return Data(base64Encoded: body.components(separatedBy: .whitespacesAndNewlines).joined(), options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable":
            return quotedPrintable(body)
        default:
            return Data(body.utf8)
        }
    }

    private static func quotedPrintable(_ s: String) -> Data {
        var out = Data()
        let bytes = Array(s.replacingOccurrences(of: "=\n", with: "").utf8)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "="), i + 2 < bytes.count,
               let v = UInt8(String(bytes: bytes[(i + 1)...(i + 2)], encoding: .ascii) ?? "", radix: 16) {
                out.append(v); i += 3
            } else { out.append(bytes[i]); i += 1 }
        }
        return out
    }

    private static func text(_ data: Data, charset: String?, encoding: String, raw: String) -> String {
        // 7bit/8bit: Apple Mail liefert den Text schon fertig dekodiert
        if encoding != "base64" && encoding != "quoted-printable" { return raw }
        let cs = (charset ?? "utf-8").lowercased()
        let cfe = CFStringConvertIANACharSetNameToEncoding(cs as CFString)
        let enc = cfe == kCFStringEncodingInvalidId ? String.Encoding.utf8 : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfe))
        return String(data: data, encoding: enc) ?? String(decoding: data, as: UTF8.self)
    }

    /// =?UTF-8?B?…?= / =?ISO-8859-1?Q?…?= in Dateinamen und Betreffs
    static func decodeWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        let re = try? NSRegularExpression(pattern: "=\\?([^?]+)\\?([BbQq])\\?([^?]*)\\?=")
        var result = s
        for m in (re?.matches(in: s, range: NSRange(s.startIndex..., in: s)) ?? []).reversed() {
            guard let c = Range(m.range(at: 1), in: s), let e = Range(m.range(at: 2), in: s),
                  let t = Range(m.range(at: 3), in: s) else { continue }
            let data = s[e].uppercased() == "B" ? (Data(base64Encoded: String(s[t])) ?? Data())
                : quotedPrintable(s[t].replacingOccurrences(of: "_", with: " "))
            let cfe = CFStringConvertIANACharSetNameToEncoding(String(s[c]) as CFString)
            let enc = cfe == kCFStringEncodingInvalidId ? String.Encoding.utf8 : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfe))
            if let txt = String(data: data, encoding: enc), let r = Range(m.range, in: result) { result.replaceSubrange(r, with: txt) }
        }
        return result.replacingOccurrences(of: "?= =?", with: "")
    }
}

// MARK: - Apple Mail: Rohdaten, Senden mit Anhängen, Weiterleiten

extension MailClient {
    /// Rohdaten einer Mail (für HTML, Bilder, Anhänge). Sehr große Mails (> 40 MB) nur als Text.
    func source(of m: MailMessage, completion: @escaping (String?) -> Void) {
        let script = """
        tell application "Mail"
            set theMsg to missing value
            repeat with mb in (mailboxes of inbox)
                try
                    set theMsg to (first message of mb whose id is \(Int(m.messageID) ?? 0))
                    exit repeat
                end try
            end repeat
            if theMsg is missing value then return ""
            set read status of theMsg to true
            if (message size of theMsg) > 40000000 then return ""
            return source of theMsg
        end tell
        """
        Shell.osascript(script, timeout: 60) { [weak self] out, _ in
            if let i = self?.messages.firstIndex(where: { $0.id == m.id }) { self?.messages[i].read = true }
            completion((out ?? "").isEmpty ? nil : out)
        }
    }

    enum MailAction { case read, unread, flag, unflag, trash, archive }

    /// Mail bearbeiten – direkt in Apple Mail (und damit auf allen Geräten): gelesen, markiert, gelöscht, archiviert.
    func act(_ m: MailMessage, _ action: MailAction, completion: ((Bool) -> Void)? = nil) {
        let cmd: String
        switch action {
        case .read: cmd = "set read status of theMsg to true"
        case .unread: cmd = "set read status of theMsg to false"
        case .flag: cmd = "set flagged status of theMsg to true"
        case .unflag: cmd = "set flagged status of theMsg to false"
        case .trash: cmd = "delete theMsg"
        case .archive:
            cmd = """
            set acc to account of mailbox of theMsg
            set target to missing value
            repeat with n in {"Archive", "Archiv", "Archived", "All Mail", "Alle Nachrichten"}
                try
                    set target to mailbox (n as string) of acc
                    exit repeat
                end try
            end repeat
            if target is missing value then return "noarchive"
            move theMsg to target
            """
        }
        let script = """
        tell application "Mail"
            set theMsg to missing value
            repeat with mb in (mailboxes of inbox)
                try
                    set theMsg to (first message of mb whose id is \(Int(m.messageID) ?? 0))
                    exit repeat
                end try
            end repeat
            if theMsg is missing value then return "missing"
            \(cmd)
            return "ok"
        end tell
        """
        // sofort in der Liste zeigen, Mail zieht im Hintergrund nach
        switch action {
        case .read: if let i = messages.firstIndex(where: { $0.id == m.id }) { messages[i].read = true }
        case .unread: if let i = messages.firstIndex(where: { $0.id == m.id }) { messages[i].read = false }
        case .trash, .archive: messages.removeAll { $0.id == m.id }
        default: break
        }
        Shell.osascript(script, timeout: 40) { [weak self] out, _ in
            let ok = (out ?? "").contains("ok")
            if !ok, action == .trash || action == .archive { self?.messages.append(m); self?.messages.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) } }
            completion?(ok)
        }
    }

    private static let attachLines = """
        repeat with p in my splitLines(item 5 of argv)
            if (p as string) is not "" then
                tell content of msg to make new attachment with properties {file name:(POSIX file (p as string))} at after last paragraph
            end if
        end repeat
    """
    private static let helpers = """
    on splitText(t)
        set AppleScript's text item delimiters to ","
        set parts to text items of t
        set AppleScript's text item delimiters to ""
        return parts
    end splitText
    on splitLines(t)
        set AppleScript's text item delimiters to linefeed
        set parts to text items of t
        set AppleScript's text item delimiters to ""
        return parts
    end splitLines
    """

    /// Neue Mail mit Anhängen.
    func send(from account: MailAccount?, to: String, subject: String, text: String, files: [URL], completion: @escaping (Bool, String) -> Void) {
        let script = """
        on run argv
            tell application "Mail"
                set msg to make new outgoing message with properties {subject:(item 2 of argv), content:(item 3 of argv), visible:false}
                if (item 4 of argv) is not "" then set sender of msg to (item 4 of argv)
                repeat with addr in my splitText(item 1 of argv)
                    tell msg to make new to recipient at end of to recipients with properties {address:addr}
                end repeat
        \(Self.attachLines)
                delay 1
                send msg
                return "ok"
            end tell
        end run
        \(Self.helpers)
        """
        Shell.osascript(script, args: [to, subject, text, account?.addresses.first ?? "", files.map(\.path).joined(separator: "\n")], timeout: 90) { out, err in
            completion(out?.contains("ok") == true, out ?? err ?? "")
        }
    }

    /// Antworten mit Anhängen (Zitat wie in Apple Mail).
    func reply(to m: MailMessage, text: String, files: [URL], completion: @escaping (Bool, String) -> Void) {
        let script = """
        on run argv
            tell application "Mail"
                set theMsg to missing value
                repeat with mb in (mailboxes of inbox)
                    try
                        set theMsg to (first message of mb whose id is \(Int(m.messageID) ?? 0))
                        exit repeat
                    end try
                end repeat
                if theMsg is missing value then return "nicht gefunden"
                set msg to reply theMsg without opening window
                set content of msg to (item 3 of argv) & return & return & (content of msg)
        \(Self.attachLines)
                delay 1
                send msg
                return "ok"
            end tell
        end run
        \(Self.helpers)
        """
        Shell.osascript(script, args: ["", "", text, "", files.map(\.path).joined(separator: "\n")], timeout: 90) { out, err in
            completion(out?.contains("ok") == true, out ?? err ?? "")
        }
    }

    /// Weiterleiten – die Anhänge der Original-Mail gehen mit.
    func forward(_ m: MailMessage, to: String, text: String, files: [URL], completion: @escaping (Bool, String) -> Void) {
        let script = """
        on run argv
            tell application "Mail"
                set theMsg to missing value
                repeat with mb in (mailboxes of inbox)
                    try
                        set theMsg to (first message of mb whose id is \(Int(m.messageID) ?? 0))
                        exit repeat
                    end try
                end repeat
                if theMsg is missing value then return "nicht gefunden"
                set msg to forward theMsg without opening window
                repeat with addr in my splitText(item 1 of argv)
                    tell msg to make new to recipient at end of to recipients with properties {address:addr}
                end repeat
                if (item 3 of argv) is not "" then set content of msg to (item 3 of argv) & return & return & (content of msg)
        \(Self.attachLines)
                delay 1
                send msg
                return "ok"
            end tell
        end run
        \(Self.helpers)
        """
        Shell.osascript(script, args: [to, "", text, "", files.map(\.path).joined(separator: "\n")], timeout: 90) { out, err in
            completion(out?.contains("ok") == true, out ?? err ?? "")
        }
    }
}

// MARK: - Anzeige

/// HTML-Mail sicher anzeigen: kein JavaScript, Links öffnen im Browser, externe Bilder optional blockiert.
struct MailHTMLView: NSViewRepresentable {
    let html: String
    var allowRemote: Bool

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = context.coordinator
        return v
    }

    func updateNSView(_ v: WKWebView, context: Context) {
        let key = "\(html.hashValue)-\(allowRemote)"
        guard context.coordinator.loaded != key else { return }
        context.coordinator.loaded = key
        v.loadHTMLString(Self.wrap(html, allowRemote: allowRemote), baseURL: nil)
    }

    static func wrap(_ html: String, allowRemote: Bool) -> String {
        let csp = "default-src 'none'; img-src data: \(allowRemote ? "https: http:" : ""); style-src 'unsafe-inline' \(allowRemote ? "https:" : ""); font-src data: \(allowRemote ? "https:" : "")"
        let head = """
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html { background: #ffffff; }
          body { margin: 0; padding: 18px 22px; font: 14px -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color: #1d1d1f; word-wrap: break-word; }
          img { max-width: 100%; height: auto; }
          pre.salenta-text { white-space: pre-wrap; font: 14px -apple-system, sans-serif; margin: 0; }
          blockquote { border-left: 3px solid #d2d2d7; margin: 8px 0; padding-left: 12px; color: #555; }
          table { max-width: 100% !important; }
        </style>
        """
        // Kopfteil einsetzen: nach <head …>, sonst nach <html …>, sonst alles einrahmen
        for (pattern, wrapHead) in [("<head[^>]*>", false), ("<html[^>]*>", true)] {
            if let r = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                var h = html
                h.insert(contentsOf: wrapHead ? "<head>\(head)</head>" : head, at: r.upperBound)
                return h
            }
        }
        return "<!doctype html><html><head><meta charset=\"utf-8\">\(head)</head><body>\(html)</body></html>"
    }

    static func plain(_ text: String) -> String {
        let esc = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        // Links klickbar machen
        let linked = esc.replacingOccurrences(of: "(https?://[^\\s<]+)", with: "<a href=\"$1\">$1</a>", options: .regularExpression)
        return "<pre class=\"salenta-text\">\(linked)</pre>"
    }

    func makeCoordinator() -> Coord { Coord() }
    final class Coord: NSObject, WKNavigationDelegate {
        var loaded = ""
        func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if a.navigationType == .linkActivated, let u = a.request.url {
                NSWorkspace.shared.open(u)
                decisionHandler(.cancel)
            } else {
                decisionHandler(a.request.url?.scheme == "about" || a.navigationType == .other ? .allow : .cancel)
            }
        }
    }
}

enum AttachmentFiles {
    /// Anhang in einen privaten Temp-Ordner schreiben (für Vorschau, Öffnen, Aufträge).
    static func write(_ a: MailAttachment) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("salenta-mail/\(a.id.uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = a.filename.replacingOccurrences(of: "/", with: "-")
        let u = dir.appendingPathComponent(safe.isEmpty ? "Anhang" : safe)
        return (try? a.data.write(to: u)) != nil ? u : nil
    }

    static func save(_ a: MailAttachment) {
        let p = NSSavePanel()
        p.nameFieldStringValue = a.filename
        if p.runModal() == .OK, let u = p.url { try? a.data.write(to: u) }
    }
}

/// Anhänge als Kacheln: Bilder mit Vorschau, sonst Symbol + Name + Größe.
struct AttachmentStrip: View {
    let items: [MailAttachment]
    var onToMission: ([URL]) -> Void

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(String(format: L("%d Anhänge"), items.count), systemImage: "paperclip").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Alle sichern …")) { saveAll() }.buttonStyle(.link).font(.caption)
                    Button(L("An Auftrag geben")) { onToMission(items.compactMap(AttachmentFiles.write)) }.buttonStyle(.link).font(.caption)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(items) { a in AttachmentTile(a: a) } }
                }
            }
        }
    }

    private func saveAll() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = L("Hier sichern")
        guard p.runModal() == .OK, let dir = p.url else { return }
        for a in items { try? a.data.write(to: dir.appendingPathComponent(a.filename)) }
    }
}

struct AttachmentTile: View {
    let a: MailAttachment
    @State private var thumb: NSImage?

    var body: some View {
        Button { if let u = AttachmentFiles.write(a) { NSWorkspace.shared.open(u) } } label: {
            VStack(spacing: 4) {
                Group {
                    if let t = thumb {
                        Image(nsImage: t).resizable().scaledToFill()
                    } else {
                        Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (a.filename as NSString).pathExtension) ?? .data))
                            .resizable().scaledToFit().padding(10)
                    }
                }
                .frame(width: 96, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                Text(a.filename).font(.caption2).lineLimit(1).frame(width: 96)
                Text(a.size).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .help(L("Öffnen (Doppelklick in Vorschau)"))
        .contextMenu {
            Button(L("Öffnen")) { if let u = AttachmentFiles.write(a) { NSWorkspace.shared.open(u) } }
            Button(L("Sichern unter …")) { AttachmentFiles.save(a) }
            Button(L("Im Finder zeigen")) { if let u = AttachmentFiles.write(a) { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
        }
        .task {
            if a.isImage, let img = NSImage(data: a.data) { thumb = img; return }
            guard let u = AttachmentFiles.write(a) else { return }
            let req = QLThumbnailGenerator.Request(fileAt: u, size: CGSize(width: 192, height: 144), scale: 2, representationTypes: .thumbnail)
            if let r = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { thumb = r.nsImage }
        }
    }
}

/// Anhänge beim Schreiben: hinzufügen per Knopf oder Ziehen.
struct ComposeAttachments: View {
    @Binding var files: [URL]
    @State private var dropping = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { add() } label: { Label(L("Anhang hinzufügen"), systemImage: "paperclip") }
                Text(L("oder Dateien hierher ziehen")).font(.caption).foregroundStyle(.tertiary)
            }
            if !files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(files, id: \.self) { u in
                            HStack(spacing: 4) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 16, height: 16)
                                Text(u.lastPathComponent).font(.caption).lineLimit(1)
                                Button { files.removeAll { $0 == u } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary).help(L("Anhang entfernen"))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        }
                    }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(dropping ? Color.accentColor : .clear, style: StrokeStyle(lineWidth: 2, dash: [5])))
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { DispatchQueue.main.async { if !files.contains(u) { files.append(u) } } } }
            }
            return true
        }
    }

    private func add() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true; p.canChooseDirectories = false
        if p.runModal() == .OK { files += p.urls.filter { !files.contains($0) } }
    }
}
