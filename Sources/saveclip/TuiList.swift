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
    var unsafeMode: Bool = false
    var message: String? = nil
    var messageExpiry: Date? = nil
    var dividerHighlight: Bool = false
    var previewLines: Int = 3
    var previewScrollOffset: Int = 0
    var previewContent: [String]? = nil

    mutating func setItems(_ items: [ListItem]) {
        allItems = items
        filteredItems = items
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
        previewScrollOffset = 0
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
    // Layout: header(1) + preview(dynamic) + separator(1) + list(N) + prompt(1)
    static let headerLines = 1
    static let separatorLines = 1
    static let promptLines = 1
    static let fixedOverhead = headerLines + separatorLines + promptLines // 3

    static func overhead(previewLines: Int) -> Int {
        return fixedOverhead + previewLines
    }

    static func visibleRows(termHeight: Int, previewLines: Int = 3) -> Int {
        return max(1, termHeight - overhead(previewLines: previewLines))
    }

    static func render(state: ListState, termWidth: Int, termHeight: Int) -> ANSIBuffer {
        var buf = ANSIBuffer()
        buf.hideCursor()

        let width = termWidth
        let pvLines = state.previewLines
        let listRows = visibleRows(termHeight: termHeight, previewLines: pvLines)
        var row = 1

        // ── Header ──
        buf.moveTo(row: row, col: 1)
        buf.clearLine()

        // Left side: mode + count
        let modeLabel = state.viewMode.label
        let countLabel = "\(state.filteredItems.count)/\(state.allItems.count)"

        buf.write(" \u{1B}[38;5;75m\(modeLabel)\u{1B}[0m")  // soft blue mode
        buf.write(" \u{1B}[38;5;243m\(countLabel)\u{1B}[0m") // gray count

        if state.unsafeMode {
            buf.write("  \u{1B}[1;38;5;203mUNSAFE\u{1B}[0m")
        }

        // Right side: hints or flash message
        let hints: String
        if let msg = state.message {
            hints = " - \(msg) "
        } else {
            hints = "enter=copy  ^O=out  ^D=del  ^P=pin  ^T=top  ^F=freq  ^B=branch"
        }
        let hintsStart = max(1, width - hints.count - 1)
        buf.moveTo(row: row, col: hintsStart)
        buf.write("\u{1B}[38;5;243m\(hints)\u{1B}[0m")
        row += 1

        // ── Preview ──
        let maxPW = width - 4
        for i in 0..<pvLines {
            buf.moveTo(row: row, col: 1)
            buf.clearLine()
            if let lines = state.previewContent {
                let lineIdx = i + state.previewScrollOffset
                if lineIdx < lines.count {
                    let line = truncateANSI(lines[lineIdx], maxWidth: maxPW)
                    buf.write("  \(line)")
                }
            } else if let item = state.selectedItem {
                if item.sensitive {
                    if i == 0 { buf.write("  \u{1B}[38;5;167m[sensitive content]\u{1B}[0m") }
                } else {
                    let lines = item.preview.components(separatedBy: "\\n")
                    if i < lines.count {
                        let line = String(lines[i].prefix(maxPW))
                        buf.write("  \u{1B}[38;5;250m\(line)\u{1B}[0m")
                    }
                }
            }
            row += 1
        }

        // ── Separator (draggable divider) ──
        buf.moveTo(row: row, col: 1)
        buf.clearLine()
        let sepW = min(width, 120)
        if state.dividerHighlight {
            buf.write("\u{1B}[1;38;5;75m")  // bold blue when dragging
            buf.write(String(repeating: "\u{2550}", count: sepW))  // double line ═
        } else {
            buf.write("\u{1B}[38;5;238m")
            buf.write(String(repeating: "\u{2500}", count: sepW))
        }
        buf.reset()
        row += 1

        // ── List (bottom-up: selected near prompt) ──
        let isEmpty = state.filteredItems.isEmpty
        if isEmpty {
            // Center "no entries" message
            for i in 0..<listRows {
                buf.moveTo(row: row, col: 1)
                buf.clearLine()
                if i == listRows / 2 {
                    let msg = state.allItems.isEmpty ? "No clipboard entries" : "No matches"
                    let pad = max(0, (width - msg.count) / 2)
                    buf.write("\u{1B}[38;5;243m")
                    buf.write(String(repeating: " ", count: pad))
                    buf.write(msg)
                    buf.reset()
                }
                row += 1
            }
        } else {
            for i in 0..<listRows {
                buf.moveTo(row: row, col: 1)
                buf.clearLine()
                let visualIndex = listRows - 1 - i
                let idx = state.scrollOffset + visualIndex
                if idx < state.filteredItems.count {
                    let item = state.filteredItems[idx]
                    let isSelected = idx == state.cursor
                    renderListItem(buf: &buf, item: item, selected: isSelected, width: width, showCount: state.viewMode == .frequent)
                }
                row += 1
            }
        }

        // ── Prompt ──
        buf.moveTo(row: row, col: 1)
        buf.clearLine()
        buf.write(" \u{1B}[38;5;75m>\u{1B}[0m ")
        buf.write(state.query)
        buf.showCursor()

        return buf
    }

    /// Greyscale values for newest and oldest items, mapped to 232-255 range.
    /// Updated dynamically from terminal OSC queries.
    static var newestGrey: Int = 255
    static var oldestGrey: Int = 236

    /// Update from terminal luminance values (0.0-1.0).
    static func updateColors(fgLuminance: Double, bgLuminance: Double) {
        let darkMode = bgLuminance < 0.5

        // Map to 232-255 greyscale
        let fgG = 232 + Int(round(fgLuminance * 23.0))
        let bgG = 232 + Int(round(bgLuminance * 23.0))

        // Newest: 30% brighter/darker than fg, away from bg
        let boost = Int(round(23.0 * 0.3))
        if darkMode {
            newestGrey = min(255, fgG + boost)
        } else {
            newestGrey = max(232, fgG - boost)
        }

        // Oldest: 80% of the way from fg toward bg
        oldestGrey = fgG + Int(round(0.8 * Double(bgG - fgG)))
        oldestGrey = max(232, min(255, oldestGrey))
    }

    /// Grey gradient based on age — interpolates between newest and oldest grey.
    private static func heatColor(for item: ListItem) -> Int {
        let age = -item.entry.timestamp.timeIntervalSinceNow
        let t: Double  // 0.0 = newest, 1.0 = oldest
        if age < 600          { t = 0.0 }
        else if age < 3600    { t = 0.15 }
        else if age < 6*3600  { t = 0.3 }
        else if age < 86400   { t = 0.45 }
        else if age < 3*86400 { t = 0.6 }
        else if age < 7*86400 { t = 0.75 }
        else if age < 30*86400 { t = 0.9 }
        else                  { t = 1.0 }

        let grey = Double(newestGrey) + t * Double(oldestGrey - newestGrey)
        return max(232, min(255, Int(round(grey))))
    }

    private static func renderListItem(buf: inout ANSIBuffer, item: ListItem, selected: Bool, width: Int, showCount: Bool = false) {
        let heat = heatColor(for: item)

        // Right-align age in 3 chars
        let age = String(item.age.prefix(3))
        let agePad = String(repeating: " ", count: max(0, 3 - age.count))
        let ageStr = "\(agePad)\(age)"

        // Build plain-text badges
        var badgeTxt = ""
        if showCount && item.copyCount > 1 { badgeTxt += "x\(item.copyCount) " }
        if item.sensitive { badgeTxt += "[sensitive] " }
        if item.pinned { badgeTxt += "[pin] " }
        if item.branch != "main" { badgeTxt += "\(item.branch) " }

        // marker(1) + age(3) + space(1) + badges + preview
        let metaWidth = 1 + 3 + 1 + badgeTxt.count
        let maxPreview = max(10, width - metaWidth - 1)

        var preview = item.preview
        if preview.hasSuffix("\\n") { preview = String(preview.dropLast(2)) }
        preview = preview.replacingOccurrences(of: "\\n", with: " ")

        if item.sensitive {
            let visible = String(preview.prefix(8))
            let masked = String(repeating: "*", count: min(max(0, preview.count - 8), 20))
            preview = "\(visible)\(masked)"
        }

        preview = String(preview.prefix(maxPreview))

        if selected {
            let line = ">\(ageStr) \(badgeTxt)\(preview)"
            let padded = line.count < width ? line + String(repeating: " ", count: width - line.count) : line
            buf.write("\u{1B}[1;7;38;5;230m\(padded)\u{1B}[0m")
        } else {
            buf.write(" ")
            buf.write("\u{1B}[38;5;\(heat)m\(ageStr)\u{1B}[0m ")
            if showCount && item.copyCount > 1 { buf.write("\u{1B}[38;5;116mx\(item.copyCount)\u{1B}[0m ") }
            if item.sensitive { buf.write("\u{1B}[38;5;167m[sensitive]\u{1B}[0m ") }
            if item.pinned { buf.write("\u{1B}[38;5;222m[pin]\u{1B}[0m ") }
            if item.branch != "main" { buf.write("\u{1B}[38;5;176m\(item.branch)\u{1B}[0m ") }
            let textColor = item.sensitive ? "38;5;167" : "38;5;\(heat)"
            buf.write("\u{1B}[\(textColor)m\(preview)\u{1B}[0m")
        }
    }

    static func truncateANSI(_ str: String, maxWidth: Int) -> String {
        var result = ""
        var visible = 0
        var inEscape = false

        for ch in str {
            if inEscape {
                result.append(ch)
                if ch.isLetter { inEscape = false }
            } else if ch == "\u{1B}" {
                inEscape = true
                result.append(ch)
            } else if visible < maxWidth {
                result.append(ch)
                visible += 1
            } else {
                break
            }
        }
        result += "\u{1B}[0m"
        return result
    }

    static func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = bytes / 1024
        if kb < 1024 { return "\(kb) KB" }
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.1f MB", mb)
    }
}
