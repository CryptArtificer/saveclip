import AppKit
import ArgumentParser
import Foundation

// MARK: - TuiResult

enum TuiResult {
    case copied(Int64)
    case stdout(Int64)
    case cancelled
}

// MARK: - TuiCommand

struct TuiCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tui",
        abstract: "Interactive clipboard picker (built-in TUI)"
    )

    @Option(name: .shortAndLong, help: "Number of entries to load")
    var count: Int = 200

    @Option(name: .shortAndLong, help: "Initial search query")
    var query: String?

    @Flag(name: [.long, .short, .customShort("\u{0001F631}")], help: "Disable sensitive content redaction")
    var unsafe: Bool = false

    func run() throws {
        guard Terminal.isTTY() else {
            // Fall back to list if not a terminal
            let config = Config.load()
            let storage = try Storage(config: config)
            let entries = storage.list(limit: count)
            for entry in entries {
                print("\(entry.id)\t\(entry.preview)")
            }
            return
        }

        let runner = try TuiRunner(count: count, initialQuery: query, unsafe: unsafe)
        let result = runner.run()

        switch result {
        case .stdout(let id):
            // Print to stdout after TUI cleanup — this is the pipe output
            let config = Config.load()
            let storage = try Storage(config: config)
            guard let entry = storage.get(id: id) else { return }
            guard let data = storage.readClipData(entry: entry) else { return }
            switch entry.type {
            case .text, .filePath:
                if let str = String(data: data, encoding: .utf8) {
                    print(str, terminator: "")
                }
            case .image:
                FileHandle.standardOutput.write(data)
            }
        case .copied(let id):
            let config2 = Config.load()
            let storage2 = try Storage(config: config2)
            if let entry = storage2.get(id: id) {
                switch entry.type {
                case .text:
                    let text = entry.preview
                        .replacingOccurrences(of: "\\n", with: "\n")
                    if text.utf8.count < 1024 {
                        // Short text → stdout for print -z
                        print(text, terminator: "")
                    } else {
                        FileHandle.standardError.write("Copied text (\(text.utf8.count / 1024)KB) to clipboard\n".data(using: .utf8)!)
                    }
                case .image:
                    let size = ListRenderer.formatSize(entry.totalSize)
                    FileHandle.standardError.write("Copied image (\(size)) to clipboard\n".data(using: .utf8)!)
                case .filePath:
                    FileHandle.standardError.write("Copied file path to clipboard\n".data(using: .utf8)!)
                }
            }
        case .cancelled:
            break
        }
    }
}

// MARK: - TuiRunner

final class TuiRunner {
    private let storage: Storage
    private let config: Config
    private var state: ListState
    private let maxCount: Int
    private var needsRender = true
    private var lastCols: Int = 0
    private var lastRows: Int = 0

    // For signal cleanup
    private static var shared: TuiRunner?

    // Auto-refresh tracking
    private var lastEntryTimestamp: Double = 0
    private var pollCounter: Int = 0
    private var colorPollCounter: Int = 0

    // Double-click tracking
    private var lastClickRow: Int = -1
    private var lastClickTime: Date = .distantPast

    // Divider drag tracking
    private var isDraggingDivider = false
    private var dragStartRow: Int = 0
    private var dragStartPreviewLines: Int = 0

    // Search debounce
    private var lastKeystrokeTime: Date = .distantPast
    private var pendingSearch = false

    // Preview debounce + cache
    private var lastCursorMoveTime: Date = .distantPast
    private var pendingPreviewId: Int64? = nil
    private var previewCache: [Int64: [String]] = [:]

    // bat path (detected once at startup)
    private static let batPath: String? = {
        for path in ["/opt/homebrew/bin/bat", "/usr/local/bin/bat"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }()

    init(count: Int, initialQuery: String?, unsafe: Bool = false) throws {
        self.config = Config.load()
        self.storage = try Storage(config: config)
        self.maxCount = count
        self.state = ListState()
        state.previewLines = TuiRunner.loadPreviewLines()

        if let q = initialQuery {
            state.query = q
        }
        state.unsafeMode = unsafe

        TuiRunner.shared = self
    }

    func run() -> TuiResult {
        setupSignals()

        Terminal.enableRawMode()

        // Detect terminal colors before entering alternate screen
        if let colors = Terminal.queryColors() {
            ListRenderer.updateColors(fgLuminance: colors.fg, bgLuminance: colors.bg)
        }

        Terminal.enterAlternateScreen()
        Terminal.enableMouse()
        defer {
            Terminal.disableMouse()
            Terminal.leaveAlternateScreen()
            Terminal.disableRawMode()
            TuiRunner.shared = nil
        }

        // Initial load
        let (c, r) = Terminal.size()
        lastCols = c; lastRows = r

        // Default preview to ~1/3 of screen if saved value is small
        if state.previewLines < 5 {
            state.previewLines = max(8, r / 3)
        }

        loadEntries()
        lastEntryTimestamp = storage.latestTimestamp() ?? 0

        // Load initial preview
        if let item = state.selectedItem {
            loadPreview(for: item.id)
        }

        // Main event loop
        while true {
            state.clearExpiredMessage()

            // Poll terminal size — handles resize from any source
            let (cols, rows) = Terminal.size()
            if cols != lastCols || rows != lastRows {
                lastCols = cols; lastRows = rows
                previewCache.removeAll()
                if state.selectedItem != nil { schedulePreviewLoad() }
                needsRender = true
            }

            if needsRender {
                let buf = ListRenderer.render(state: state, termWidth: lastCols, termHeight: lastRows)
                buf.flush()
                needsRender = false
            }

            guard let key = Terminal.readKey() else {
                // Search debounce (200ms)
                if pendingSearch && Date().timeIntervalSince(lastKeystrokeTime) >= 0.2 {
                    pendingSearch = false
                    loadEntries()
                    schedulePreviewLoad()
                    needsRender = true
                }

                // Preview debounce (150ms)
                if let pid = pendingPreviewId,
                   Date().timeIntervalSince(lastCursorMoveTime) >= 0.15 {
                    loadPreview(for: pid)
                    pendingPreviewId = nil
                    needsRender = true
                }

                // Auto-refresh (~1s)
                pollCounter += 1
                if pollCounter >= 10 {
                    pollCounter = 0
                    if let latest = storage.latestTimestamp(), latest > lastEntryTimestamp {
                        lastEntryTimestamp = latest
                        let oldId = state.selectedItem?.id
                        loadEntries()
                        if state.selectedItem?.id != oldId {
                            schedulePreviewLoad()
                        }
                        needsRender = true
                    }
                }
                // Re-query terminal colors every ~5s to react to theme changes
                colorPollCounter += 1
                if colorPollCounter >= 50 {
                    colorPollCounter = 0
                    if let colors = Terminal.queryColors() {
                        let oldN = ListRenderer.newestGrey
                        let oldO = ListRenderer.oldestGrey
                        ListRenderer.updateColors(fgLuminance: colors.fg, bgLuminance: colors.bg)
                        if ListRenderer.newestGrey != oldN || ListRenderer.oldestGrey != oldO {
                            needsRender = true
                        }
                    }
                }
                if state.message != nil { needsRender = true }
                continue
            }

            switch key {
            case .enter:
                if let item = state.selectedItem {
                    try? storage.bumpToFront(id: item.id)
                    copyToClipboard(entry: item.entry)
                    return .copied(item.id)
                }

            case .ctrl("o"):
                if let item = state.selectedItem {
                    return .stdout(item.id)
                }

            case .ctrl("c"), .escape:
                return .cancelled

            case .ctrl("d"):
                if let item = state.selectedItem {
                    do {
                        try storage.delete(id: item.id)
                        state.flash("Deleted \(item.id)")
                        previewCache.removeValue(forKey: item.id)
                        loadEntries()
                    } catch {
                        state.flash("Delete failed")
                    }
                    needsRender = true
                }

            case .ctrl("p"):
                if let item = state.selectedItem {
                    do {
                        if item.pinned {
                            try storage.unpin(id: item.id)
                            state.flash("Unpinned \(item.id)")
                        } else {
                            try storage.pin(id: item.id)
                            state.flash("Pinned \(item.id)")
                        }
                        loadEntries()
                    } catch {
                        state.flash("Pin failed")
                    }
                    needsRender = true
                }

            case .ctrl("f"):
                switch state.viewMode {
                case .frequent:
                    state.viewMode = .all
                default:
                    state.viewMode = .frequent
                }
                loadEntries()
                needsRender = true

            case .ctrl("b"):
                let currentBranch = BranchState.current()
                switch state.viewMode {
                case .branchFiltered:
                    state.viewMode = .all
                default:
                    state.viewMode = .branchFiltered(currentBranch)
                }
                loadEntries()
                needsRender = true

            case .ctrl("t"):
                if let item = state.selectedItem {
                    do {
                        try storage.bumpToFront(id: item.id)
                        state.flash("Bumped to front")
                        state.cursor = 0
                        state.scrollOffset = 0
                        loadEntries()
                        schedulePreviewLoad()
                    } catch {
                        state.flash("Bump failed")
                    }
                    needsRender = true
                }

            case .ctrl("r"):
                loadEntries()
                previewCache.removeAll()
                state.flash("Reloaded")
                needsRender = true


            case .up:
                state.moveCursor(by: 1, visibleRows: ListRenderer.visibleRows(termHeight: lastRows, previewLines: state.previewLines))
                schedulePreviewLoad()
                needsRender = true

            case .down:
                state.moveCursor(by: -1, visibleRows: ListRenderer.visibleRows(termHeight: lastRows, previewLines: state.previewLines))
                schedulePreviewLoad()
                needsRender = true

            case .pageUp:
                state.pageDown(visibleRows: ListRenderer.visibleRows(termHeight: lastRows, previewLines: state.previewLines))
                schedulePreviewLoad()
                needsRender = true

            case .pageDown:
                state.pageUp(visibleRows: ListRenderer.visibleRows(termHeight: lastRows, previewLines: state.previewLines))
                schedulePreviewLoad()
                needsRender = true

            case .home:
                state.home(visibleRows: ListRenderer.visibleRows(termHeight: lastRows, previewLines: state.previewLines))
                schedulePreviewLoad()
                needsRender = true

            case .end:
                state.end(visibleRows: ListRenderer.visibleRows(termHeight: lastRows, previewLines: state.previewLines))
                schedulePreviewLoad()
                needsRender = true

            case .scrollUp(let row, _):
                let previewStart = 1 + ListRenderer.headerLines
                let previewEnd = previewStart + state.previewLines
                if row >= previewStart && row < previewEnd {
                    if state.previewScrollOffset > 0 {
                        state.previewScrollOffset -= 1
                        needsRender = true
                    }
                } else {
                    state.moveCursor(by: -1, visibleRows: ListRenderer.visibleRows(termHeight: lastRows, previewLines: state.previewLines))
                    schedulePreviewLoad()
                    needsRender = true
                }

            case .scrollDown(let row, _):
                let previewStart = 1 + ListRenderer.headerLines
                let previewEnd = previewStart + state.previewLines
                if row >= previewStart && row < previewEnd {
                    let totalLines = state.previewContent?.count ?? 0
                    let maxScroll = max(0, totalLines - state.previewLines)
                    if state.previewScrollOffset < maxScroll {
                        state.previewScrollOffset += 1
                        needsRender = true
                    }
                } else {
                    state.moveCursor(by: 1, visibleRows: ListRenderer.visibleRows(termHeight: lastRows, previewLines: state.previewLines))
                    schedulePreviewLoad()
                    needsRender = true
                }

            case .mouseClick(let row, _):
                let sepRow = 1 + ListRenderer.headerLines + state.previewLines
                if row == sepRow {
                    isDraggingDivider = true
                    dragStartRow = row
                    dragStartPreviewLines = state.previewLines
                    state.dividerHighlight = true
                    needsRender = true
                } else {
                    let listRows = ListRenderer.visibleRows(termHeight: lastRows, previewLines: state.previewLines)
                    let listStartRow = 1 + ListRenderer.headerLines + state.previewLines + ListRenderer.separatorLines
                    if row >= listStartRow && row < listStartRow + listRows {
                        let visualIndex = (listStartRow + listRows - 1) - row
                        let idx = state.scrollOffset + visualIndex
                        if idx < state.filteredItems.count {
                            let now = Date()
                            let isDoubleClick = idx == state.cursor
                                && row == lastClickRow
                                && now.timeIntervalSince(lastClickTime) < 0.4
                            lastClickRow = row
                            lastClickTime = now
                            state.cursor = idx
                            state.previewScrollOffset = 0
                            schedulePreviewLoad()
                            needsRender = true

                            if isDoubleClick, let item = state.selectedItem {
                                try? storage.bumpToFront(id: item.id)
                                copyToClipboard(entry: item.entry)
                                return .copied(item.id)
                            }
                        }
                    }
                }

            case .mouseDrag(let row, _):
                if isDraggingDivider {
                    let delta = row - dragStartRow
                    let newPV = dragStartPreviewLines + delta
                    let maxPV = lastRows - ListRenderer.fixedOverhead - 1
                    let clamped = max(0, min(newPV, maxPV))
                    if clamped != state.previewLines {
                        state.previewLines = clamped
                        needsRender = true
                    }
                }

            case .mouseRelease(_, _):
                if isDraggingDivider {
                    isDraggingDivider = false
                    state.dividerHighlight = false
                    TuiRunner.savePreviewLines(state.previewLines)
                    previewCache.removeAll()
                    schedulePreviewLoad()
                    needsRender = true
                }

            case .backspace:
                if !state.query.isEmpty {
                    state.query.removeLast()
                    state.cursor = 0
                    state.scrollOffset = 0
                    lastKeystrokeTime = Date()
                    pendingSearch = true
                    needsRender = true
                }

            case .char(let ch):
                state.query.append(ch)
                state.cursor = 0
                state.scrollOffset = 0
                lastKeystrokeTime = Date()
                pendingSearch = true
                needsRender = true

            default:
                break
            }
        }
    }

    // MARK: - Data loading

    private func loadEntries() {
        let now = Date()
        let calendar = Calendar.current
        var entries: [ClipEntry]

        let query = state.query.trimmingCharacters(in: .whitespaces)

        if !query.isEmpty {
            // FTS5/BM25 first, Levenshtein fallback if sparse
            let branch: String? = {
                if case .branchFiltered(let b) = state.viewMode { return b }
                return nil
            }()
            entries = storage.search(query: query, limit: maxCount, branch: branch)
            if entries.count < 5 {
                let fuzzy = storage.fuzzyFallback(query: query, limit: maxCount, branch: branch)
                let existing = Set(entries.map(\.id))
                entries += fuzzy.filter { !existing.contains($0.id) }
            }
        } else {
            switch state.viewMode {
            case .all:
                entries = storage.list(limit: maxCount)
            case .frequent:
                let freqs = storage.mostFrequent(limit: maxCount)
                state.setItems(freqs.map { makeListItem($0.entry, now: now, calendar: calendar) })
                return
            case .branchFiltered(let branch):
                entries = storage.list(limit: maxCount, branch: branch)
            }
        }

        state.setItems(entries.map { makeListItem($0, now: now, calendar: calendar) })
    }

    private func makeListItem(_ entry: ClipEntry, now: Date, calendar: Calendar) -> ListItem {
        let age = relativeTime(from: entry.timestamp, to: now, calendar: calendar)
        // TUI-side sensitive detection (broader than daemon's capture-time check)
        let sensitive: Bool
        if state.unsafeMode {
            sensitive = false
        } else {
            sensitive = entry.sensitive || (entry.type == .text && SensitiveDetector.isSensitive(entry.preview))
        }
        return ListItem(
            id: entry.id,
            age: age,
            pinned: entry.pinned,
            copyCount: entry.copyCount,
            branch: entry.branch,
            type: entry.type,
            preview: entry.preview,
            sensitive: sensitive,
            entry: entry
        )
    }

    // MARK: - Clipboard

    private func copyToClipboard(entry: ClipEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if let reps = storage.readBundleRepresentations(entry: entry) {
            for rep in reps {
                pasteboard.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.uti))
            }
        } else if let data = storage.readClipData(entry: entry) {
            switch entry.type {
            case .text, .filePath:
                if let str = String(data: data, encoding: .utf8) {
                    pasteboard.setString(str, forType: .string)
                }
            case .image:
                pasteboard.setData(data, forType: .png)
            }
        }
    }

    // MARK: - Signals

    private func setupSignals() {
        signal(SIGINT) { _ in
            Terminal.disableMouse()
            Terminal.leaveAlternateScreen()
            Terminal.disableRawMode()
            exit(0)
        }
        signal(SIGTERM) { _ in
            Terminal.disableMouse()
            Terminal.leaveAlternateScreen()
            Terminal.disableRawMode()
            exit(0)
        }
    }

    // MARK: - Preview

    private func schedulePreviewLoad() {
        lastCursorMoveTime = Date()
        state.previewScrollOffset = 0
        if let item = state.selectedItem {
            if let cached = previewCache[item.id] {
                state.previewContent = cached
                pendingPreviewId = nil
            } else {
                // Show DB preview as fast fallback
                state.previewContent = item.preview.components(separatedBy: "\\n")
                pendingPreviewId = item.id
            }
        } else {
            state.previewContent = nil
            pendingPreviewId = nil
        }
    }

    private func loadPreview(for id: Int64) {
        guard let entry = storage.get(id: id) else { return }

        var lines: [String]

        switch entry.type {
        case .image:
            lines = renderImagePreview(entry: entry)
        case .filePath:
            var parts = ["File | \(ListRenderer.formatSize(entry.totalSize))"]
            parts.append(entry.preview)
            if let app = entry.sourceApp { parts.append("from \(app)") }
            lines = parts
        case .text:
            if entry.sensitive || (!state.unsafeMode && SensitiveDetector.isSensitive(entry.preview)) {
                lines = ["[sensitive content]"]
            } else if entry.totalSize > 64 * 1024 {
                // Too large — stick with DB preview
                lines = entry.preview.components(separatedBy: "\\n")
            } else if let data = storage.readClipData(entry: entry),
                      let text = String(data: data, encoding: .utf8) {
                let truncated = String(text.prefix(16384))
                if let highlighted = highlightWithBat(truncated, width: lastCols - 4) {
                    lines = highlighted.components(separatedBy: "\n")
                } else {
                    lines = truncated.components(separatedBy: "\n")
                }
            } else {
                lines = entry.preview.components(separatedBy: "\\n")
            }
        }

        lines = lines.map(Self.highlightURLs)
        previewCache[id] = lines
        state.previewContent = lines

        // Keep cache bounded
        if previewCache.count > 50 {
            let keysToRemove = Array(previewCache.keys.prefix(25))
            for k in keysToRemove { previewCache.removeValue(forKey: k) }
        }
    }

    private static func guessExtension(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("{") || t.hasPrefix("[") { return "json" }
        if t.hasPrefix("<!") || t.hasPrefix("<html") || t.hasPrefix("<div") { return "html" }
        if t.hasPrefix("<?xml") || t.hasPrefix("<svg") { return "xml" }
        if t.hasPrefix("---\n") { return "yaml" }
        if t.hasPrefix("#!") {
            if t.contains("python") { return "py" }
            if t.contains("node") { return "js" }
            if t.contains("ruby") { return "rb" }
            return "sh"
        }
        let u = text.uppercased()
        if u.contains("SELECT ") || u.contains("INSERT ") || u.contains("CREATE TABLE") || u.contains("ALTER TABLE") { return "sql" }
        if text.contains("#include") { return "c" }
        if text.contains("func ") && (text.contains("let ") || text.contains("var ")) { return "swift" }
        if text.contains("def ") && text.contains(":") && !text.contains(";") { return "py" }
        if text.contains("function") || text.contains("const ") || text.contains("=> {") { return "js" }
        if text.contains("fn ") && text.contains("->") { return "rs" }
        if text.contains("package ") && text.contains(":=") { return "go" }
        return nil
    }

    private func highlightWithBat(_ text: String, width: Int) -> String? {
        guard let bat = TuiRunner.batPath else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bat)
        guard let ext = TuiRunner.guessExtension(text) else { return nil }
        proc.arguments = [
            "--color=always", "--style=plain", "--paging=never",
            "--theme=ansi", "--wrap=character", "--terminal-width=\(width)",
            "--file-name=clip.\(ext)"
        ]
        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            inPipe.fileHandleForWriting.write(text.data(using: .utf8)!)
            inPipe.fileHandleForWriting.closeFile()
            proc.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func renderImagePreview(entry: ClipEntry) -> [String] {
        // Build metadata line
        var meta: [String] = []
        if let data = storage.readClipData(entry: entry),
           let nsImage = NSImage(data: data),
           let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            meta.append("\(cg.width)\u{00D7}\(cg.height)")
        }
        meta.append(ListRenderer.formatSize(entry.totalSize))
        if let app = entry.sourceApp { meta.append(app) }
        let metaLine = "\u{1B}[38;5;243m\(meta.joined(separator: " | "))\u{1B}[0m"

        // 1 line or no image data → metadata only
        guard state.previewLines > 1,
              let data = storage.readClipData(entry: entry),
              let nsImage = NSImage(data: data),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return [metaLine]
        }

        let availW = lastCols - 4
        let imageRows = state.previewLines - 1  // reserve 1 line for metadata
        let availH = imageRows * 2  // 2 pixels per character row

        let scaleX = Double(availW) / Double(cgImage.width)
        let scaleY = Double(availH) / Double(cgImage.height)
        let scale = min(scaleX, scaleY)

        let tw = max(1, Int(Double(cgImage.width) * scale))
        let th = max(2, Int(Double(cgImage.height) * scale))
        let h = th % 2 == 0 ? th : th + 1

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: tw, height: h,
            bitsPerComponent: 8, bytesPerRow: tw * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return [metaLine]
        }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: tw, height: h))
        guard let pixels = ctx.data else {
            return [metaLine]
        }

        let buf = pixels.bindMemory(to: UInt8.self, capacity: tw * h * 4)
        var lines: [String] = []

        for cr in 0..<(h / 2) {
            var line = ""
            let topRow = cr * 2
            let botRow = cr * 2 + 1

            for col in 0..<tw {
                let ti = (topRow * tw + col) * 4
                let bi = (botRow * tw + col) * 4
                line += "\u{1B}[38;2;\(buf[ti]);\(buf[ti+1]);\(buf[ti+2])m\u{1B}[48;2;\(buf[bi]);\(buf[bi+1]);\(buf[bi+2])m\u{2580}"
            }
            line += "\u{1B}[0m"
            lines.append(line)
        }

        lines.append(metaLine)
        return lines
    }

    private static let urlRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "((?:https?|ftp|ssh|file)://[^\\s)>\\]\\x{1B}]+)")
    }()

    private static func highlightURLs(_ line: String) -> String {
        guard line.contains("://"), let regex = urlRegex else { return line }
        let ns = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return line }

        var result = ""
        var pos = 0
        for match in matches {
            let r = match.range
            result += ns.substring(with: NSRange(location: pos, length: r.location - pos))
            result += "\u{1B}[38;5;73m" + ns.substring(with: r) + "\u{1B}[39m"
            pos = r.location + r.length
        }
        result += ns.substring(from: pos)
        return result
    }

    // MARK: - Helpers

    private static let stateFile = Config.defaultDir + "/tui-state"

    static func loadPreviewLines() -> Int {
        guard let str = try? String(contentsOfFile: stateFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let n = Int(str) else { return 3 }
        return max(0, n)
    }

    static func savePreviewLines(_ n: Int) {
        try? String(n).write(toFile: stateFile, atomically: true, encoding: .utf8)
    }

    private func writeStderr(_ s: String) {
        FileHandle.standardError.write(s.data(using: .utf8)!)
    }
}
