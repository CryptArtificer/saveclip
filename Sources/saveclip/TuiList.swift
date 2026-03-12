import Foundation

// MARK: - ListItem

struct ListItem {
    let id: Int64
    let age: String
    let pinned: Bool
    let copyCount: Int
    let branch: String
    let type: ClipType
    let preview: String
    let sensitive: Bool
    let entry: ClipEntry
}

// MARK: - ViewMode

enum ViewMode: Equatable {
    case all
    case frequent
    case branchFiltered(String)

    var label: String {
        switch self {
        case .all: return "ALL"
        case .frequent: return "FREQ"
        case .branchFiltered(let b): return b
        }
    }
}

// MARK: - ListState

struct ListState {
    var allItems: [ListItem] = []
    var filteredItems: [ListItem] = []
    var query: String = ""
    var cursor: Int = 0
    var scrollOffset: Int = 0
    var viewMode: ViewMode = .all
    var message: String? = nil
    var messageExpiry: Date? = nil

    mutating func setItems(_ items: [ListItem]) {
        allItems = items
        filter()
    }

    mutating func filter() {
        if query.isEmpty {
            filteredItems = allItems
        } else {
            let q = query.lowercased()
            filteredItems = allItems.filter { $0.preview.lowercased().contains(q) }
        }
        // Clamp cursor
        if filteredItems.isEmpty {
            cursor = 0
            scrollOffset = 0
        } else {
            cursor = min(cursor, filteredItems.count - 1)
        }
    }

    mutating func moveCursor(by delta: Int, visibleRows: Int) {
        guard !filteredItems.isEmpty else { return }
        cursor = max(0, min(filteredItems.count - 1, cursor + delta))
        adjustScroll(visibleRows: visibleRows)
    }

    mutating func pageUp(visibleRows: Int) {
        moveCursor(by: -visibleRows, visibleRows: visibleRows)
    }

    mutating func pageDown(visibleRows: Int) {
        moveCursor(by: visibleRows, visibleRows: visibleRows)
    }

    mutating func home(visibleRows: Int) {
        cursor = 0
        adjustScroll(visibleRows: visibleRows)
    }

    mutating func end(visibleRows: Int) {
        cursor = max(0, filteredItems.count - 1)
        adjustScroll(visibleRows: visibleRows)
    }

    private mutating func adjustScroll(visibleRows: Int) {
        if cursor < scrollOffset {
            scrollOffset = cursor
        }
        if cursor >= scrollOffset + visibleRows {
            scrollOffset = cursor - visibleRows + 1
        }
    }

    var selectedItem: ListItem? {
        guard !filteredItems.isEmpty, cursor < filteredItems.count else { return nil }
        return filteredItems[cursor]
    }

    mutating func flash(_ msg: String) {
        message = msg
        messageExpiry = Date().addingTimeInterval(2.0)
    }

    mutating func clearExpiredMessage() {
        if let expiry = messageExpiry, Date() > expiry {
            message = nil
            messageExpiry = nil
        }
    }
}

// MARK: - ListRenderer

enum ListRenderer {
    // Layout: header(1) + preview(3) + separator(1) + list(N) + prompt(1)
    static let headerLines = 1
    static let previewLines = 3
    static let separatorLines = 1
    static let promptLines = 1
    static let overhead = headerLines + previewLines + separatorLines + promptLines // 6

    static func visibleRows(regionHeight: Int) -> Int {
        return max(1, regionHeight - overhead)
    }

    static func render(state: ListState, region: Region, termWidth: Int) -> ANSIBuffer {
        var buf = ANSIBuffer()
        buf.hideCursor()

        let width = termWidth
        let listRows = visibleRows(regionHeight: region.height)
        var row = region.startRow

        // ── Header ──
        buf.moveTo(row: row, col: 1)
        buf.clearLine()
        let modeLabel = state.viewMode.label
        let countLabel = "\(state.filteredItems.count)/\(state.allItems.count)"
        buf.style("1;36") // bold cyan
        buf.write(" \(modeLabel)")
        buf.reset()
        buf.style("2") // dim
        buf.write(" \(countLabel)")
        buf.reset()

        // Keybind hints (right-aligned)
        let hints: String
        if let msg = state.message {
            hints = " \(msg) "
        } else {
            hints = "enter=copy  ^O=stdout  ^D=del  ^P=pin  ^F=freq  ^B=branch"
        }
        let hintsStart = max(1, width - hints.count)
        buf.moveTo(row: row, col: hintsStart)
        buf.style("2")
        buf.write(hints)
        buf.reset()
        row += 1

        // ── Preview ──
        let selected = state.selectedItem
        for i in 0..<previewLines {
            buf.moveTo(row: row, col: 1)
            buf.clearLine()
            if let item = selected {
                let previewText = previewLine(item: item, lineIndex: i, width: width)
                if !previewText.isEmpty {
                    buf.style("2") // dim
                    buf.write("  \(previewText)")
                    buf.reset()
                }
            }
            row += 1
        }

        // ── Separator ──
        buf.moveTo(row: row, col: 1)
        buf.clearLine()
        buf.style("2")
        let sep = String(repeating: "─", count: min(width, 120))
        buf.write(sep)
        buf.reset()
        row += 1

        // ── List ──
        for i in 0..<listRows {
            buf.moveTo(row: row, col: 1)
            buf.clearLine()
            let idx = state.scrollOffset + i
            if idx < state.filteredItems.count {
                let item = state.filteredItems[idx]
                let isSelected = idx == state.cursor
                renderListItem(buf: &buf, item: item, selected: isSelected, width: width)
            }
            row += 1
        }

        // ── Prompt ──
        buf.moveTo(row: row, col: 1)
        buf.clearLine()
        buf.style("1") // bold
        buf.write("search clipboard> ")
        buf.reset()
        buf.write(state.query)
        buf.showCursor()

        return buf
    }

    private static func renderListItem(buf: inout ANSIBuffer, item: ListItem, selected: Bool, width: Int) {
        let marker = selected ? "\u{25B8} " : "  "
        let idStr = String(item.id)
        let ageStr = item.age.padding(toLength: 4, withPad: " ", startingAt: 0)
        let pin = item.pinned ? "*" : " "
        let freq = item.copyCount > 1 ? "×\(item.copyCount) " : ""
        let branch = item.branch != "main" ? "[\(item.branch)] " : ""

        // Calculate available width for preview
        let metaWidth = marker.count + idStr.count + 1 + ageStr.count + 1 + pin.count + 1 + freq.count + branch.count
        let maxPreview = max(10, width - metaWidth - 1)

        var preview = item.preview
        if preview.hasSuffix("\\n") { preview = String(preview.dropLast(2)) }
        // Replace literal \n with spaces for single-line display
        preview = preview.replacingOccurrences(of: "\\n", with: " ")

        if selected {
            buf.style("1;7") // bold + inverse
        }

        if item.sensitive {
            let visible = String(preview.prefix(8))
            let masked = String(repeating: "•", count: min(max(0, preview.count - 8), 20))
            preview = "[sensitive] \(visible)\(masked)"
        }

        preview = String(preview.prefix(maxPreview))

        if selected {
            buf.write(marker)
            buf.style("2;7") // dim + inverse
            buf.write(idStr)
            buf.write(" ")
            buf.write(ageStr)
            buf.style("1;7") // bold + inverse
            buf.write(" ")
            if item.pinned {
                buf.style("33;7") // yellow
                buf.write(pin)
                buf.style("1;7")
            } else {
                buf.write(pin)
            }
            buf.write(" ")
            if !freq.isEmpty {
                buf.style("36;7") // cyan
                buf.write(freq)
                buf.style("1;7")
            }
            if !branch.isEmpty {
                buf.style("35;7") // magenta
                buf.write(branch)
                buf.style("1;7")
            }
            buf.write(preview)
            buf.reset()
        } else {
            buf.write(marker)
            buf.style("2") // dim
            buf.write(idStr)
            buf.write(" ")
            buf.write(ageStr)
            buf.reset()
            buf.write(" ")
            if item.pinned {
                buf.style("33") // yellow
                buf.write(pin)
                buf.reset()
            } else {
                buf.write(pin)
            }
            buf.write(" ")
            if !freq.isEmpty {
                buf.style("36") // cyan
                buf.write(freq)
                buf.reset()
            }
            if !branch.isEmpty {
                buf.style("35") // magenta
                buf.write(branch)
                buf.reset()
            }
            if item.sensitive {
                buf.style("31") // red
                buf.write(preview)
                buf.reset()
            } else {
                buf.style("1") // bold
                buf.write(preview)
                buf.reset()
            }
        }
    }

    private static func previewLine(item: ListItem, lineIndex: Int, width: Int) -> String {
        if item.sensitive {
            if lineIndex == 0 { return "[sensitive content]" }
            return ""
        }

        // Split preview on literal \n to show multi-line content
        let lines = item.preview.components(separatedBy: "\\n")
        guard lineIndex < lines.count else { return "" }
        let line = lines[lineIndex]
        let maxWidth = width - 4
        if line.count > maxWidth {
            return String(line.prefix(maxWidth - 1)) + "…"
        }
        return line
    }
}
