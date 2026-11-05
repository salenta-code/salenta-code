import AgenticOSKit
import AppKit
import SwiftUI
import WebKit

/// Hält pro Panel eine WKWebView am Leben: Logins und offene Chats bleiben beim Seitenwechsel erhalten.
/// Cookies liegen dauerhaft im Standard-Datenspeicher der App.
final class WebPool: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    static let shared = WebPool()

    /// Safari-Kennung: Google und Microsoft lassen Logins in eingebetteten Ansichten sonst manchmal nicht zu.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

    @Published var titles: [String: String] = [:]
    @Published var loading: Set<String> = []
    @Published var failed: [String: String] = [:]

    private var views: [String: WKWebView] = [:]
    private var popups: [NSWindow] = []

    func webView(for panel: WebPanel) -> WKWebView {
        if let v = views[panel.id] { return v }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let v = WKWebView(frame: .zero, configuration: config)
        v.customUserAgent = Self.userAgent
        v.allowsBackForwardNavigationGestures = true
        v.allowsMagnification = true
        v.navigationDelegate = self
        v.uiDelegate = self
        if #available(macOS 13.3, *) { v.isInspectable = true }
        views[panel.id] = v
        if let url = URL(string: panel.url) { v.load(URLRequest(url: url)) }
        return v
    }

    func existing(_ id: String) -> WKWebView? { views[id] }

    func reload(_ panel: WebPanel) {
        failed[panel.id] = nil
        if let v = views[panel.id] {
            if v.url == nil, let url = URL(string: panel.url) { v.load(URLRequest(url: url)) } else { v.reload() }
        }
    }

    func home(_ panel: WebPanel) {
        guard let url = URL(string: panel.url) else { return }
        views[panel.id]?.load(URLRequest(url: url))
    }

    /// Setzt einen Auftrag in das Eingabefeld von ChatGPT / claude.ai ein (ohne zu senden).
    func insertPrompt(_ text: String, panelID: String, attempt: Int = 0) {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              var json = String(data: data, encoding: .utf8) else { return }
        json = String(json.dropFirst().dropLast())
        let js = """
        (function(t){
          var el = document.querySelector('#prompt-textarea') || document.querySelector('div.ProseMirror[contenteditable="true"]')
                || document.querySelector('[contenteditable="true"]') || document.querySelector('textarea');
          if (!el) return false;
          el.focus();
          if (el.tagName === 'TEXTAREA') {
            el.value = t; el.dispatchEvent(new Event('input', {bubbles: true}));
          } else {
            document.execCommand('selectAll', false, null);
            document.execCommand('insertText', false, t);
          }
          return true;
        })(\(json))
        """
        let delay = attempt == 0 ? 0.8 : 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let v = self.views[panelID] else {
                if attempt < 6 { self?.insertPrompt(text, panelID: panelID, attempt: attempt + 1) }
                return
            }
            v.evaluateJavaScript(js) { result, _ in
                if (result as? Bool) != true, attempt < 6 {
                    self.insertPrompt(text, panelID: panelID, attempt: attempt + 1)
                }
            }
        }
    }

    func forget(_ id: String) {
        views[id]?.removeFromSuperview()
        views[id] = nil
    }

    private func panelID(of webView: WKWebView) -> String? {
        views.first { $0.value === webView }?.key
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let id = panelID(of: webView) { loading.insert(id); failed[id] = nil }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let id = panelID(of: webView) else { return }
        loading.remove(id)
        titles[id] = webView.title
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let id = panelID(of: webView) else { return }
        loading.remove(id)
        let ns = error as NSError
        if ns.code != NSURLErrorCancelled { failed[id] = error.localizedDescription }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if let id = panelID(of: webView) { loading.remove(id) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // mailto:, tel:, zoommtg: … an die passende Mac-App geben.
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data", "file"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: Downloads -> ~/Downloads

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? Paths.home
        var target = dir.appendingPathComponent(suggestedFilename)
        var n = 1
        let base = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        while FileManager.default.fileExists(atPath: target.path) {
            n += 1
            target = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
        }
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {
        NSSound(named: "Glass")?.play()
    }

    // MARK: Popups (Google-/Microsoft-Login, window.open)

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680), configuration: configuration)
        popup.customUserAgent = Self.userAgent
        popup.uiDelegate = self
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Salenta Code"
        window.contentView = popup
        window.center()
        window.makeKeyAndOrderFront(nil)
        popups.append(window)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let w = popups.first(where: { $0.contentView === webView }) {
            w.close()
            popups.removeAll { $0 === w }
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Abbrechen")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }
}

/// Bettet die gehaltene WKWebView eines Panels ein.
struct WebContainer: NSViewRepresentable {
    let panel: WebPanel

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let v = WebPool.shared.webView(for: panel)
        if v.superview !== container { attach(to: container) }
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        for v in container.subviews { v.removeFromSuperview() }
    }

    private func attach(to container: NSView) {
        let v = WebPool.shared.webView(for: panel)
        v.removeFromSuperview()
        v.frame = container.bounds
        v.autoresizingMask = [.width, .height]
        container.addSubview(v)
    }
}

struct WebPanelView: View {
    let panel: WebPanel
    @AppStorage("web.chrome") private var useChrome = false
    @AppStorage("web.embedded") private var embeddedRaw = ""

    /// Lokale Seiten bleiben eingebettet, alles andere läuft in Chrome mit deinen Logins.
    private var inChrome: Bool {
        useChrome && Chrome.installed && !panel.url.contains("127.0.0.1") && !panel.url.contains("localhost")
            && !embeddedRaw.split(separator: ",").contains(Substring(panel.id))
    }

    var body: some View {
        if let path = panel.app {
            MacAppPanelView(panel: panel, path: path)
        } else if inChrome {
            ChromePanelView(panel: panel) {
                embeddedRaw = (embeddedRaw.split(separator: ",").map(String.init) + [panel.id]).joined(separator: ",")
            }
        } else {
            EmbeddedPanelView(panel: panel) {
                embeddedRaw = embeddedRaw.split(separator: ",").map(String.init).filter { $0 != panel.id }.joined(separator: ",")
            }
        }
    }
}

/// Web-App läuft in Chrome: Seite holt das Chrome-Fenster nach vorn (einmal automatisch pro Start).
struct ChromePanelView: View {
    let panel: WebPanel
    let embedHere: () -> Void
    static var opened: Set<String> = []

    var body: some View {
        ContentUnavailableView {
            Label("\(panel.title) läuft in Chrome", systemImage: panel.symbol)
        } description: {
            Text("Mit deinen Chrome-Logins, Passwörtern und Erweiterungen. Ein Klick holt das Fenster nach vorn.")
        } actions: {
            VStack(spacing: Grid.m) {
                Button { show() } label: { Label("In Chrome zeigen", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button("Lieber hier im Fenster anzeigen", action: embedHere).buttonStyle(.link)
            }
        }
        .navigationTitle(panel.title)
        .onAppear {
            if !Self.opened.contains(panel.id) { Self.opened.insert(panel.id); show() }
        }
    }

    private func show() {
        if let url = URL(string: panel.url) { Chrome.show(url) }
    }
}

struct EmbeddedPanelView: View {
    let panel: WebPanel
    let backToChrome: () -> Void
    @ObservedObject private var pool = WebPool.shared
    @EnvironmentObject private var system: SystemStatus

    var body: some View {
        VStack(spacing: 0) {
            Group {
                ZStack {
                    WebContainer(panel: panel)
                        .id(panel.id)
                    if let err = pool.failed[panel.id] {
                        ContentUnavailableView {
                            Label("\(panel.title) lädt nicht", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(err)
                        } actions: {
                            Button("Neu laden") { pool.reload(panel) }
                        }
                        .background(.background)
                    }
                }
            }
        }
        .navigationTitle(panel.title)
        .navigationSubtitle(pool.titles[panel.id] ?? "")
        .toolbar {
            ToolbarItemGroup {
                Button { pool.existing(panel.id)?.goBack() } label: { Label("Zurück", systemImage: "chevron.left") }.help(L("Zurück"))
                Button { pool.existing(panel.id)?.goForward() } label: { Label("Vor", systemImage: "chevron.right") }.help(L("Vor"))
                Button { pool.home(panel) } label: { Label("Startseite", systemImage: "house") }.help(L("Startseite"))
                Button { pool.reload(panel) } label: {
                    Label("Neu laden", systemImage: pool.loading.contains(panel.id) ? "hourglass" : "arrow.clockwise")
                }
                .keyboardShortcut("r")
                Button {
                    let url = pool.existing(panel.id)?.url ?? URL(string: panel.url)
                    if let url { if Chrome.installed { Chrome.open(url) } else { NSWorkspace.shared.open(url) } }
                } label: { Label("In Chrome öffnen", systemImage: "globe") }.help(L("In Chrome öffnen"))

            }
        }
    }
}

