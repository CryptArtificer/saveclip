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

    @Option(name: .long, help: "Height in terminal rows (0 = 40%)")
    var height: Int = 0

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

        let runner = try TuiRunner(count: count, initialQuery: query, height: height, unsafe: unsafe)
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
    private let region: Region
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
    private let debugLog: FileHandle? = {
        let path = "/tmp/saveclip-resize.log"
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    private func dlog(_ msg: String) {
        let ts = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 10000))
        debugLog?.write("[\(ts)] \(msg)\n".data(using: .utf8)!)
    }

    init(count: Int, initialQuery: String?, height: Int, unsafe: Bool = false) throws {
        self.config = Config.load()
        self.storage = try Storage(config: config)
        self.maxCount = count
        self.state = ListState()
        state.previewLines = TuiRunner.loadPreviewLines()

        if let q = initialQuery {
            state.query = q
        }
        state.unsafeMode = unsafe

        // Calculate region height
        let (cols, rows) = Terminal.size()
        let h: Int
        if height > 0 {
            h = min(height, rows)
        } else {
            h = max(10, Int(Double(rows) * 0.4))
        }
        _ = cols // suppress warning

        self.region = Region(height: h)

        TuiRunner.shared = self
    }

    func run() -> TuiResult {
        // Install signal handlers for clean exit
        setupSignals()

        Terminal.enableRawMode()

        // Detect terminal fg/bg colors for heatmap
        if let colors = Terminal.queryColors() {
            ListRenderer.updateColors(fgLuminance: colors.fg, bgLuminance: colors.bg)
            dlog("COLORS fg=\(colors.fg) bg=\(colors.bg) -> newest=\(ListRenderer.newestGrey) oldest=\(ListRenderer.oldestGrey)")
        } else {
            dlog("COLORS query failed, using defaults newest=\(ListRenderer.newestGrey) oldest=\(ListRenderer.oldestGrey)")
        }

        Terminal.enableMouse()
        defer {
            Terminal.disableMouse()
            Terminal.disableRawMode()
            region.release()
            TuiRunner.shared = nil
        }

        // Initial load
        let (c, r) = Terminal.size()
        lastCols = c; lastRows = r
        dlog("INIT size=\(c)x\(r) region.start=\(region.startRow) region.h=\(region.height)")
        loadEntries()
        lastEntryTimestamp = storage.latestTimestamp() ?? 0

        // Main event loop
        while true {
            state.clearExpiredMessage()

            // Poll terminal size — handles resize from any source
            let (cols, rows) = Terminal.size()
            if cols != lastCols || rows != lastRows {
                dlog("RESIZE \(lastCols)x\(lastRows) -> \(cols)x\(rows)")
                lastCols = cols; lastRows = rows
                region.handleResize()
                dlog("AFTER handleResize start=\(region.startRow) h=\(region.height)")
                needsRender = true
            }

            if needsRender {
                let buf = ListRenderer.render(state: state, region: region, termWidth: lastCols)
                buf.flush()
                needsRender = false
            }

            guard let key = Terminal.readKey() else {
                // Timeout (100ms) — poll for new entries every ~1s
                pollCounter += 1
                if pollCounter >= 10 {
                    pollCounter = 0
                    if let latest = storage.latestTimestamp(), latest > lastEntryTimestamp {
                        lastEntryTimestamp = latest
                        loadEntries()
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
                    Terminal.disableMouse()
                    Terminal.disableRawMode()
                    region.release()
                    try? storage.bumpToFront(id: item.id)
                    copyToClipboard(entry: item.entry)
                    TuiRunner.shared = nil
                    return .copied(item.id)
                }

            case .ctrl("o"):
                if let item = state.selectedItem {
                    Terminal.disableMouse()
                    Terminal.disableRawMode()
                    region.release()
                    TuiRunner.shared = nil
                    return .stdout(item.id)
                }

            case .ctrl("c"), .escape:
                return .cancelled

            case .ctrl("d"):
                if let item = state.selectedItem {
                    do {
                        try storage.delete(id: item.id)
                        state.flash("Deleted \(item.id)")
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

            case .ctrl("r"):
                loadEntries()
                state.flash("Reloaded")
                needsRender = true


            case .up:
                state.moveCursor(by: 1, visibleRows: ListRenderer.visibleRows(regionHeight: region.height, previewLines: state.previewLines))
                needsRender = true

            case .down:
                state.moveCursor(by: -1, visibleRows: ListRenderer.visibleRows(regionHeight: region.height, previewLines: state.previewLines))
                needsRender = true

            case .pageUp:
                state.pageDown(visibleRows: ListRenderer.visibleRows(regionHeight: region.height, previewLines: state.previewLines))
                needsRender = true

            case .pageDown:
                state.pageUp(visibleRows: ListRenderer.visibleRows(regionHeight: region.height, previewLines: state.previewLines))
                needsRender = true

            case .home:
                state.home(visibleRows: ListRenderer.visibleRows(regionHeight: region.height, previewLines: state.previewLines))
                needsRender = true

            case .end:
                state.end(visibleRows: ListRenderer.visibleRows(regionHeight: region.height, previewLines: state.previewLines))
                needsRender = true

            case .scrollUp(let row, _):
                let previewEnd = region.startRow + ListRenderer.headerLines + state.previewLines
                if row >= region.startRow + ListRenderer.headerLines && row < previewEnd {
                    // Scroll in preview area
                    if state.previewScrollOffset > 0 {
                        state.previewScrollOffset -= 1
                        needsRender = true
                    }
                } else {
                    state.moveCursor(by: -1, visibleRows: ListRenderer.visibleRows(regionHeight: region.height, previewLines: state.previewLines))
                    needsRender = true
                }

            case .scrollDown(let row, _):
                let previewEnd = region.startRow + ListRenderer.headerLines + state.previewLines
                if row >= region.startRow + ListRenderer.headerLines && row < previewEnd {
                    // Scroll in preview area
                    if let item = state.selectedItem {
                        let totalLines = ListRenderer.previewTotalLines(item: item)
                        let maxScroll = max(0, totalLines - state.previewLines)
                        if state.previewScrollOffset < maxScroll {
                            state.previewScrollOffset += 1
                            needsRender = true
                        }
                    }
                } else {
                    state.moveCursor(by: 1, visibleRows: ListRenderer.visibleRows(regionHeight: region.height, previewLines: state.previewLines))
                    needsRender = true
                }

            case .mouseClick(let row, _):
                // Check if clicking the divider
                let sepRow = region.startRow + ListRenderer.headerLines + state.previewLines
                if row == sepRow {
                    isDraggingDivider = true
                    dragStartRow = row
                    dragStartPreviewLines = state.previewLines
                    state.dividerHighlight = true
                    needsRender = true
                } else {
                    // List item click
                    let listRows = ListRenderer.visibleRows(regionHeight: region.height, previewLines: state.previewLines)
                    let listStartRow = region.startRow + ListRenderer.headerLines + state.previewLines + ListRenderer.separatorLines
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
                            needsRender = true

                            if isDoubleClick, let item = state.selectedItem {
                                Terminal.disableMouse()
                                Terminal.disableRawMode()
                                region.release()
                                try? storage.bumpToFront(id: item.id)
                                copyToClipboard(entry: item.entry)
                                TuiRunner.shared = nil
                                return .copied(item.id)
                            }
                        }
                    }
                }

            case .mouseDrag(let row, _):
                if isDraggingDivider {
                    // Dragging down = more preview, dragging up = less preview
                    let delta = row - dragStartRow
                    let newPV = dragStartPreviewLines + delta
                    // Min 0 preview lines, max = region height - fixed overhead - 1 list row
                    let maxPV = region.height - ListRenderer.fixedOverhead - 1
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
                    needsRender = true
                }

            case .backspace:
                if !state.query.isEmpty {
                    state.query.removeLast()
                    state.cursor = 0
                    state.scrollOffset = 0
                    loadEntries()
                    needsRender = true
                }

            case .char(let ch):
                state.query.append(ch)
                state.cursor = 0
                state.scrollOffset = 0
                loadEntries()
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
        let entries: [ClipEntry]

        let query = state.query.trimmingCharacters(in: .whitespaces)

        if !query.isEmpty {
            // FTS5 search across entire DB
            let branch: String? = {
                if case .branchFiltered(let b) = state.viewMode { return b }
                return nil
            }()
            entries = storage.search(query: query, limit: maxCount, branch: branch)
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
        // SIGINT/SIGTERM — restore terminal
        signal(SIGINT) { _ in
            Terminal.disableMouse()
            Terminal.disableRawMode()
            TuiRunner.shared?.region.release()
            exit(0)
        }
        signal(SIGTERM) { _ in
            Terminal.disableMouse()
            Terminal.disableRawMode()
            TuiRunner.shared?.region.release()
            exit(0)
        }
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
