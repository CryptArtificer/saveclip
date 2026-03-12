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
        case .copied, .cancelled:
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

    // For SIGWINCH handling
    private static var shared: TuiRunner?
    private static var resizeFlag = false

    init(count: Int, initialQuery: String?, height: Int, unsafe: Bool = false) throws {
        self.config = Config.load()
        self.storage = try Storage(config: config)
        self.maxCount = count
        self.state = ListState()

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
        // Install signal handlers
        setupSignals()

        Terminal.enableRawMode()
        defer {
            Terminal.disableRawMode()
            region.release()
            TuiRunner.shared = nil
        }

        // Initial load
        loadEntries()
        state.filter()

        let visibleRows = ListRenderer.visibleRows(regionHeight: region.height)

        // Main event loop
        while true {
            state.clearExpiredMessage()

            if needsRender {
                let (cols, _) = Terminal.size()
                let buf = ListRenderer.render(state: state, region: region, termWidth: cols)
                buf.flush()
                needsRender = false
            }

            // Check resize flag
            if TuiRunner.resizeFlag {
                TuiRunner.resizeFlag = false
                needsRender = true
                continue
            }

            guard let key = Terminal.readKey() else {
                // Timeout — check for expired messages
                if state.message != nil { needsRender = true }
                continue
            }

            switch key {
            case .enter:
                if let item = state.selectedItem {
                    Terminal.disableRawMode()
                    region.release()
                    copyToClipboard(entry: item.entry)
                    writeStderr("Copied entry \(item.id)\n")
                    TuiRunner.shared = nil
                    return .copied(item.id)
                }

            case .ctrl("o"):
                if let item = state.selectedItem {
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
                        state.filter()
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
                        state.filter()
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
                state.filter()
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
                state.filter()
                needsRender = true

            case .ctrl("r"):
                loadEntries()
                state.filter()
                state.flash("Reloaded")
                needsRender = true


            case .up:
                state.moveCursor(by: -1, visibleRows: visibleRows)
                needsRender = true

            case .down:
                state.moveCursor(by: 1, visibleRows: visibleRows)
                needsRender = true

            case .pageUp:
                state.pageUp(visibleRows: visibleRows)
                needsRender = true

            case .pageDown:
                state.pageDown(visibleRows: visibleRows)
                needsRender = true

            case .home:
                state.home(visibleRows: visibleRows)
                needsRender = true

            case .end:
                state.end(visibleRows: visibleRows)
                needsRender = true

            case .backspace:
                if !state.query.isEmpty {
                    state.query.removeLast()
                    state.cursor = 0
                    state.scrollOffset = 0
                    state.filter()
                    needsRender = true
                }

            case .char(let ch):
                state.query.append(ch)
                state.cursor = 0
                state.scrollOffset = 0
                state.filter()
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
        let items: [ListItem]

        switch state.viewMode {
        case .all:
            let entries = storage.list(limit: maxCount)
            items = entries.map { makeListItem($0, now: now, calendar: calendar) }

        case .frequent:
            let freqs = storage.mostFrequent(limit: maxCount)
            items = freqs.map { makeListItem($0.entry, now: now, calendar: calendar) }

        case .branchFiltered(let branch):
            let entries = storage.list(limit: maxCount, branch: branch)
            items = entries.map { makeListItem($0, now: now, calendar: calendar) }
        }

        state.setItems(items)
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
        // SIGWINCH for terminal resize
        signal(SIGWINCH) { _ in
            TuiRunner.resizeFlag = true
        }

        // SIGINT/SIGTERM — restore terminal
        signal(SIGINT) { _ in
            Terminal.disableRawMode()
            TuiRunner.shared?.region.release()
            exit(0)
        }
        signal(SIGTERM) { _ in
            Terminal.disableRawMode()
            TuiRunner.shared?.region.release()
            exit(0)
        }
    }

    // MARK: - Helpers

    private func writeStderr(_ s: String) {
        FileHandle.standardError.write(s.data(using: .utf8)!)
    }
}
