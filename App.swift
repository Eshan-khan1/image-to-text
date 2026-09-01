import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

let ocr = URL(string: "http://127.0.0.1:8766")!
let allowed: Set<String> = ["pdf", "png", "jpg", "jpeg"]

enum OutputMode: String, CaseIterable {
    case oneFile = "One text file"
    case perItem = "One file each"
}

enum Naming: String, CaseIterable {
    case source = "Source name"
    case dated = "Date + source"
    case fromText = "From extracted text"
    case datedText = "Date + extracted text"
}

struct Job: Identifiable {
    let id = UUID()
    var label: String
    var sourceName: String
    var image: NSImage
    var text = ""
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ImageToTextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 580, height: 800)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

@MainActor
final class Converter: ObservableObject {
    @Published var skipDupes = true
    @Published var output: OutputMode = .perItem
    @Published var naming: Naming = .datedText
    @Published var jobs: [Job] = []
    @Published var text = ""
    @Published var status = "Loading Unlimited-OCR…"
    @Published var failed = false
    @Published var busy = false
    @Published var preview: NSImage?
    @Published var ready = false
    @Published var history: [URL] = []
    private var server: Process?

    func boot() async {
        do {
            try await ensureServer()
            ready = true
            failed = false
            reloadHistory()
            status = "Unlimited-OCR ready. Drop PDF, PNG, or JPG."
        } catch {
            failed = true
            status = "Could not start Unlimited-OCR. \(error.localizedDescription)"
        }
    }

    func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .png, .jpeg]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        ingest(panel.urls)
    }

    func ingest(_ urls: [URL]) {
        var next: [Job] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard allowed.contains(ext) else { continue }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            next.append(contentsOf: expand(url))
        }
        guard !next.isEmpty else {
            failed = true
            status = "Use PDF, PNG, or JPG."
            return
        }
        var skipped = 0
        if skipDupes {
            let (kept, n) = dropLookalikes(next)
            next = kept
            skipped = n
        }
        jobs = next
        preview = next.first?.image
        text = ""
        failed = false
        var msg = "\(next.count) item\(next.count == 1 ? "" : "s") ready."
        if skipped > 0 { msg += " Skipped \(skipped) look-alike screenshot\(skipped == 1 ? "" : "s")." }
        status = msg
    }

    func convertAndSave() async {
        guard !jobs.isEmpty else { return }
        failed = false
        busy = true
        do { try await ensureServer() } catch {
            failed = true
            busy = false
            status = error.localizedDescription
            return
        }
        for i in jobs.indices {
            status = "Reading \(i + 1) of \(jobs.count)…"
            preview = jobs[i].image
            do {
                jobs[i].text = try await readImage(jobs[i].image)
            } catch {
                jobs[i].text = "(failed: \(error.localizedDescription))"
            }
            text = joined(jobs)
        }
        if skipDupes {
            let (kept, n) = dropSameText(jobs)
            if n > 0 {
                jobs = kept
                text = joined(jobs)
                status = "Dropped \(n) item\(n == 1 ? "" : "s") with the same text."
            }
        }
        busy = false
        saveFiles()
    }

    func saveFiles() {
        let stamp = dateStamp()
        var used = Set<String>()
        let files: [(String, String)] = output == .oneFile
            ? [(unique(combinedBase(stamp), &used) + ".txt", text)]
            : jobs.map { (unique(baseName($0, stamp), &used) + ".txt", $0.text) }
        for (name, body) in files {
            remember(name, body)
        }
        status = "Saved \(files.count) file\(files.count == 1 ? "" : "s") to History."
    }

    func downloadHistory(_ url: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = url.lastPathComponent
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
            status = "Downloaded \(dest.lastPathComponent)"
        } catch {
            failed = true
            status = error.localizedDescription
        }
    }

    func downloadAllHistory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Download all"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do {
            for src in history {
                let dest = dir.appendingPathComponent(src.lastPathComponent)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: src, to: dest)
            }
            status = "Downloaded \(history.count) file\(history.count == 1 ? "" : "s")."
            NSWorkspace.shared.open(dir)
        } catch {
            failed = true
            status = error.localizedDescription
        }
    }

    func openHistoryFolder() {
        NSWorkspace.shared.open(historyDir())
    }

    func deleteHistory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        reloadHistory()
    }

    func reloadHistory() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: historyDir(),
            includingPropertiesForKeys: [.creationDateKey]
        )) ?? []
        history = urls.filter { $0.pathExtension.lowercased() == "txt" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a > b
        }
    }

    private func remember(_ name: String, _ body: String) {
        try? body.write(to: historyDir().appendingPathComponent(name), atomically: true, encoding: .utf8)
        reloadHistory()
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "Copied."
        failed = false
    }

    func clear() {
        jobs = []
        text = ""
        preview = nil
        status = ready ? "Unlimited-OCR ready. Drop PDF, PNG, or JPG." : "Loading Unlimited-OCR…"
        failed = false
    }

    private func readImage(_ image: NSImage) async throws -> String {
        let data = try await post(path: "/ocr", body: ["image": try jpegBase64(image)])
        return try JSONDecoder().decode(OCR.self, from: data).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ensureServer() async throws {
        if await healthy() { return }
        startServer()
        status = "Loading Unlimited-OCR…"
        for _ in 0..<180 {
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
        let p = Process()
        p.executableURL = py
        p.arguments = [script.path]
        p.currentDirectoryURL = root
        p.standardOutput = FileHandle.standardOutput
        p.standardError = FileHandle.standardError
        try? p.run()
        server = p
    }

    private func healthy() async -> Bool {
        var req = URLRequest(url: ocr.appending(path: "/health"))
        req.timeoutInterval = 2
        guard let (_, res) = try? await URLSession.shared.data(for: req),
              let http = res as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    private func baseName(_ job: Job, _ stamp: String) -> String {
        let fromText = slug(job.text)
        switch naming {
        case .source: return job.sourceName
        case .dated: return "\(stamp)_\(job.sourceName)"
        case .fromText: return fromText.isEmpty ? job.sourceName : fromText
        case .datedText: return fromText.isEmpty ? "\(stamp)_\(job.sourceName)" : "\(stamp)_\(fromText)"
        }
    }

    private func combinedBase(_ stamp: String) -> String {
        if jobs.count == 1 { return baseName(jobs[0], stamp) }
        let fromText = slug(jobs.first?.text ?? "")
        switch naming {
        case .source: return "converted"
        case .dated: return "\(stamp)_converted"
        case .fromText: return fromText.isEmpty ? "converted" : fromText
        case .datedText: return fromText.isEmpty ? "\(stamp)_converted" : "\(stamp)_\(fromText)"
        }
    }
}

struct ContentView: View {
    @StateObject private var vm = Converter()
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("baidu/Unlimited-OCR")
                    .font(.headline)
                Spacer()
                Button("Copy") { vm.copy() }.disabled(vm.text.isEmpty)
                Button("Clear") { vm.clear() }.disabled(vm.jobs.isEmpty)
            }
            Picker("Output", selection: $vm.output) {
                ForEach(OutputMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Naming", selection: $vm.naming) {
                ForEach(Naming.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Toggle("Skip duplicate screenshots", isOn: $vm.skipDupes)
            dropZone
                .onTapGesture { if !vm.busy { vm.pick() } }
                .onDrop(of: [.fileURL], isTargeted: $hover) { loadDrop($0) }
            if !vm.jobs.isEmpty {
                Text(vm.jobs.map(\.label).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack {
                Button("Convert & Save") { Task { await vm.convertAndSave() } }
                    .disabled(vm.jobs.isEmpty || vm.busy || !vm.ready)
                    .keyboardShortcut(.defaultAction)
                Text(vm.status)
                    .font(.callout)
                    .foregroundStyle(vm.failed ? .red : .secondary)
            }
            TextEditor(text: .constant(vm.text))
                .font(.body)
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                .disabled(true)
            HStack {
                Text("History").font(.headline)
                Spacer()
                Button("Download all") { vm.downloadAllHistory() }
                    .disabled(vm.history.isEmpty)
                Button("Open folder") { vm.openHistoryFolder() }
                    .disabled(vm.history.isEmpty)
            }
            if vm.history.isEmpty {
                Text("Converted text files show up here. Download anytime.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                List(vm.history, id: \.self) { url in
                    HStack {
                        Text(url.lastPathComponent).lineLimit(1)
                        Spacer()
                        Button("Download") { vm.downloadHistory(url) }
                        Button("Delete", role: .destructive) { vm.deleteHistory(url) }
                    }
                }
                .frame(minHeight: 100, maxHeight: 160)
            }
        }
        .padding(16)
        .frame(minWidth: 500, minHeight: 640)
        .overlay { if vm.busy || !vm.ready { ProgressView().controlSize(.small) } }
        .task { await vm.boot() }
    }

    var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7]))
                .foregroundStyle(hover ? Color.accentColor : Color.secondary.opacity(0.45))
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            if let img = vm.preview {
                Image(nsImage: img).resizable().scaledToFit().padding(8)
            } else {
                Text("Drop PDF, PNG, or JPG — several at once is fine")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 220)
    }

    func loadDrop(_ providers: [NSItemProvider]) -> Bool {
        Task {
            var urls: [URL] = []
            for p in providers {
                if let url = await fileURL(p) { urls.append(url) }
            }
            await MainActor.run { vm.ingest(urls) }
        }
        return true
    }
}

func expand(_ url: URL) -> [Job] {
    let base = url.deletingPathExtension().lastPathComponent
    if url.pathExtension.lowercased() == "pdf" {
        guard let doc = PDFDocument(url: url) else { return [] }
        return (0..<doc.pageCount).compactMap { i in
            guard let page = doc.page(at: i) else { return nil }
            let img = page.thumbnail(of: CGSize(width: 1600, height: 2200), for: .mediaBox)
            return Job(label: "\(url.lastPathComponent) p.\(i + 1)", sourceName: "\(base)-p\(i + 1)", image: img)
        }
    }
    guard let img = NSImage(contentsOf: url) else { return [] }
    return [Job(label: url.lastPathComponent, sourceName: base, image: img)]
}

func fileURL(_ p: NSItemProvider) async -> URL? {
    await withCheckedContinuation { cont in
        p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            if let data = item as? Data {
                cont.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
            } else {
                cont.resume(returning: item as? URL)
            }
        }
    }
}

func jpegBase64(_ image: NSImage) throws -> String {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    else { throw URLError(.cannotDecodeContentData) }
    return jpeg.base64EncodedString()
}

func slug(_ text: String) -> String {
    let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    var out = ""
    var dash = false
    for ch in line.lowercased() {
        if ch.isLetter || ch.isNumber {
            out.append(ch)
            dash = false
        } else if !dash && !out.isEmpty {
            out.append("-")
            dash = true
        }
        if out.count >= 40 { break }
    }
    return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

func historyDir() -> URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Image to Text/History", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func dateStamp() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd-HHmm"
    return f.string(from: Date())
}

func joined(_ jobs: [Job]) -> String {
    jobs.map { "=== \($0.label) ===\n\($0.text)" }.joined(separator: "\n\n")
}

func dropLookalikes(_ jobs: [Job]) -> ([Job], Int) {
    var kept: [Job] = []
    var prints: [UInt64] = []
    var skipped = 0
    for job in jobs {
        let fp = fingerprint(job.image)
        if prints.contains(where: { ($0 ^ fp).nonzeroBitCount <= 6 }) {
            skipped += 1
            continue
        }
        prints.append(fp)
        kept.append(job)
    }
    return (kept, skipped)
}

func dropSameText(_ jobs: [Job]) -> ([Job], Int) {
    var kept: [Job] = []
    var skipped = 0
    for job in jobs {
        let key = textKey(job.text)
        if key.count >= 12, kept.contains(where: { sameText(textKey($0.text), key) }) {
            skipped += 1
            continue
        }
        kept.append(job)
    }
    return (kept, skipped)
}

func textKey(_ s: String) -> String {
    s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

func sameText(_ a: String, _ b: String) -> Bool {
    if a == b { return true }
    if a.count > 40 && b.contains(a) { return true }
    if b.count > 40 && a.contains(b) { return true }
    return false
}

func fingerprint(_ image: NSImage) -> UInt64 {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
        bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false,
        isPlanar: false, colorSpaceName: .calibratedWhite,
        bytesPerRow: 8, bitsPerPixel: 8
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 8, height: 8).fill()
    image.draw(in: NSRect(x: 0, y: 0, width: 8, height: 8), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    var vals: [Int] = []
    for y in 0..<8 {
        for x in 0..<8 {
            var px = [0]
            rep.getPixel(&px, atX: x, y: y)
            vals.append(px[0] & 0xff)
        }
    }
    let mean = vals.reduce(0, +) / max(vals.count, 1)
    var bits: UInt64 = 0
    for (i, v) in vals.enumerated() where v >= mean {
        bits |= 1 << i
    }
    return bits
}

func unique(_ base: String, _ used: inout Set<String>) -> String {
    let name = base.isEmpty ? "untitled" : base
    var n = name
    var i = 2
    while used.contains(n) {
        n = "\(name)-\(i)"
        i += 1
    }
    used.insert(n)
    return n
}

struct OCR: Decodable { var text: String }

func post(path: String, body: [String: Any]) async throws -> Data {
    var req = URLRequest(url: ocr.appending(path: path))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 600
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, res) = try await URLSession.shared.data(for: req)
    if let http = res as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        if let err = try? JSONDecoder().decode(OCRError.self, from: data) {
            throw NSError(domain: "ocr", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: err.error])
        }
        throw URLError(.badServerResponse)
    }
    return data
}

struct OCRError: Decodable { var error: String }
