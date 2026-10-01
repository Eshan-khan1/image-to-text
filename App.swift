import AppKit
import WebKit

/// Mac app window. Starts the local OCR server, then shows the app page.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var server: Process?
    private let page = URL(string: "http://127.0.0.1:8766/?shell=1")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Image to Text"
        window.minSize = NSSize(width: 760, height: 500)
        window.center()
        window.setFrameAutosaveName("ImageToText")

        let web = WKWebView(frame: window.contentView?.bounds ?? .zero)
        web.autoresizingMask = [.width, .height]
        window.contentView = web
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        Task { await open(web) }
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
        if await healthy() { return }
        startServer()
        for _ in 0..<600 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if await healthy() { return }
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

    private func healthy() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8766/health")!)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
