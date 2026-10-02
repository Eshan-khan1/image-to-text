import AppKit
import UniformTypeIdentifiers
import WebKit

/// Mac app window. Starts the local OCR server, then shows the app page.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var web: WKWebView?
    private var server: Process?
    private var saving: [ObjectIdentifier: URL] = [:]
    private let page = URL(string: "http://127.0.0.1:8766/?shell=1")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMenu()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "U Converter"
        window.minSize = NSSize(width: 760, height: 500)
        window.center()
        window.setFrameAutosaveName("UConverter")

        applyTheme(UserDefaults.standard.string(forKey: "theme"))
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "theme")
        let web = WKWebView(frame: window.contentView?.bounds ?? .zero, configuration: config)
        web.autoresizingMask = [.width, .height]
        web.uiDelegate = self
        web.navigationDelegate = self
        window.contentView = web
        self.web = web
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        Task { await open(web) }
    }

    /// Copy, paste, and other shortcuts only reach the web view through these menu items.
    private func makeMenu() -> NSMenu {
        let name = ProcessInfo.processInfo.processName
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let menu = NSMenu()
        for sub in [appMenu, editMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = sub
            menu.addItem(item)
        }
        NSApp.windowsMenu = windowMenu
        return menu
    }

    @objc private func showSettings() {
        web?.evaluateJavaScript("openSettings()")
    }

    /// Saved here too so the window frame matches the page before the page loads.
    private func applyTheme(_ choice: String?) {
        switch choice {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        server?.terminate()
    }

    private func open(_ web: WKWebView) async {
        do {
            try await ensureServer()
            web.load(URLRequest(url: page))
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not start Unlimited-OCR"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func ensureServer() async throws {
        if await serverUp() { return }
        startServer()
        for _ in 0..<120 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if await serverUp() { return }
        }
        throw URLError(.cannotConnectToHost)
    }

    private func startServer() {
        if server?.isRunning == true { return }
        let root = Bundle.main.bundleURL.deletingLastPathComponent()
        let py = root.appendingPathComponent(".venv/bin/python")
        let script = root.appendingPathComponent("ocr_server.py")
        let process = Process()
        process.executableURL = py
        process.arguments = [script.path]
        process.currentDirectoryURL = root
        try? process.run()
        server = process
    }

    /// The page shows OCR loading progress itself, so any answer from /formats means the window can open.
    private func serverUp() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8766/formats")!)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }
}

extension AppDelegate: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let choice = message.body as? String else { return }
        UserDefaults.standard.set(choice, forKey: "theme")
        applyTheme(choice)
    }
}

extension AppDelegate: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = false
        webView.evaluateJavaScript("window.pickerAccept || ''") { value, _ in
            let types = Self.contentTypes((value as? String) ?? "")
            if !types.isEmpty { panel.allowedContentTypes = types }
            panel.begin { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        }
    }

    /// WebKit doesn't pass a file input's `accept` list to the open panel, so the page hands it over.
    private static func contentTypes(_ accept: String) -> [UTType] {
        accept.split(separator: ",").compactMap { item in
            let item = item.trimmingCharacters(in: .whitespaces).lowercased()
            if item.hasPrefix(".") { return UTType(filenameExtension: String(item.dropFirst())) }
            return UTType(mimeType: item)
        }
    }
}

extension AppDelegate: WKNavigationDelegate, WKDownloadDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        decisionHandler(disposition.hasPrefix("attachment") || !navigationResponse.canShowMIMEType ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor (URL?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return completionHandler(nil) }
            try? FileManager.default.removeItem(at: url)
            self?.saving[ObjectIdentifier(download)] = url
            completionHandler(url)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = saving.removeValue(forKey: ObjectIdentifier(download)) else { return }
        tellPage("saved", url.path)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        saving.removeValue(forKey: ObjectIdentifier(download))
        tellPage("failed", error.localizedDescription)
    }

    private func tellPage(_ event: String, _ detail: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [event, detail]),
              let args = String(data: data, encoding: .utf8) else { return }
        web?.evaluateJavaScript("window.onDownload && window.onDownload(...\(args))")
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
