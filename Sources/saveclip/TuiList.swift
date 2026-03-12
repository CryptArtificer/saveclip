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

        // Left side: mode + count
        let modeLabel = state.viewMode.label
        let countLabel = "\(state.filteredItems.count)/\(state.allItems.count)"

        buf.write(" \u{1B}[38;5;75m\(modeLabel)\u{1B}[0m")  // soft blue mode
        buf.write(" \u{1B}[38;5;243m\(countLabel)\u{1B}[0m") // gray count

        if state.unsafeMode {
            buf.write("  \u{1B}[1;38;5;203m\u{26A0} UNSAFE\u{1B}[0m")
        }

        // Right side: hints or flash message
        let hints: String
        if let msg = state.message {
            hints = " \u{2022} \(msg) "
        } else {
            hints = "\u{23CE}=copy  \u{2303}O=stdout  \u{2303}D=del  \u{2303}P=pin  \u{2303}F=freq  \u{2303}B=branch"
        }
        let hintsStart = max(1, width - hints.count - 1)
        buf.moveTo(row: row, col: hintsStart)
        buf.write("\u{1B}[38;5;243m\(hints)\u{1B}[0m")
        row += 1

        // ── Preview ──
        let selected = state.selectedItem
        for i in 0..<previewLines {
            buf.moveTo(row: row, col: 1)
            buf.clearLine()
            if let item = selected {
                let previewText = previewLine(item: item, lineIndex: i, width: width)
                if !previewText.isEmpty {
                    buf.write("  \u{1B}[38;5;250m\(previewText)\u{1B}[0m")
                }
            }
            row += 1
        }

        // ── Separator ──
        buf.moveTo(row: row, col: 1)
        buf.clearLine()
        let sepW = min(width, 120)
        buf.write("\u{1B}[38;5;238m")
        buf.write(String(repeating: "\u{2500}", count: sepW))
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
                    renderListItem(buf: &buf, item: item, selected: isSelected, width: width)
                }
                row += 1
            }
        }

        // ── Prompt ──
        buf.moveTo(row: row, col: 1)
        buf.clearLine()
        buf.write(" \u{1B}[38;5;75m\u{25B8}\u{1B}[0m ")  // blue arrow
        buf.write(state.query)
        buf.showCursor()

        return buf
    }

    /// 256-color heat based on age (logarithmic bands, subdued palette)
    private static func heatColor(for item: ListItem) -> Int {
        let age = -item.entry.timestamp.timeIntervalSinceNow
        if age < 3600        { return 174 }  // < 1h   muted rose
        if age < 6 * 3600    { return 180 }  // < 6h   warm tan
        if age < 86400       { return 186 }  // < 1d   soft wheat
        if age < 3 * 86400   { return 115 }  // < 3d   sage green
        if age < 7 * 86400   { return 109 }  // < 1w   muted teal
        if age < 30 * 86400  { return 103 }  // < 1mo  dusty blue
        if age < 90 * 86400  { return 139 }  // < 3mo  muted lavender
        return 245                            // older  dim gray
    }

    private static func renderListItem(buf: inout ANSIBuffer, item: ListItem, selected: Bool, width: Int) {
        let heat = heatColor(for: item)
        let idStr = String(item.id)

        // Right-align age in 3 chars
        let age = String(item.age.prefix(3))
        let agePad = String(repeating: " ", count: max(0, 3 - age.count))
        let ageStr = "\(agePad)\(age)"

        // Build badges
        var badges = ""
        var badgeWidth = 0
        if item.pinned {
            badges += "\u{1B}[38;5;222m\u{272A}\u{1B}[0m "
            badgeWidth += 2
        }
        if item.copyCount > 1 {
            let c = "\u{00D7}\(item.copyCount)"
            badges += "\u{1B}[38;5;116m\(c)\u{1B}[0m "
            badgeWidth += c.count + 1
        }
        if item.branch != "main" {
            badges += "\u{1B}[38;5;176m\(item.branch)\u{1B}[0m "
            badgeWidth += item.branch.count + 1
        }

        // marker(2) + id + space(1) + age(3) + space(1) + badges + preview
        let metaWidth = 2 + idStr.count + 1 + 3 + 1 + badgeWidth
        let maxPreview = max(10, width - metaWidth - 1)

        var preview = item.preview
        if preview.hasSuffix("\\n") { preview = String(preview.dropLast(2)) }
        preview = preview.replacingOccurrences(of: "\\n", with: " ")

        if item.sensitive {
            let visible = String(preview.prefix(8))
            let masked = String(repeating: "\u{2022}", count: min(max(0, preview.count - 8), 20))
            preview = "\u{1F512} \(visible)\(masked)"
        }

        preview = String(preview.prefix(maxPreview))

        let textColor = item.sensitive ? "38;5;167" : "38;5;\(heat)"

        if selected {
            // Inverted bar in warm white
            buf.write("\u{1B}[7;38;5;230m \u{25B8}\u{1B}[0m")
            buf.write("\u{1B}[7;38;5;248m\(idStr)\u{1B}[0m")
            buf.write("\u{1B}[7;38;5;\(heat)m \(ageStr)\u{1B}[0m")
            buf.write("\u{1B}[7m \(badges)\u{1B}[0m")
            buf.write("\u{1B}[7;38;5;230m\(preview)\u{1B}[0m")
        } else {
            buf.write("  ")
            buf.write("\u{1B}[38;5;242m\(idStr)\u{1B}[0m")
            buf.write(" \u{1B}[38;5;\(heat)m\(ageStr)\u{1B}[0m")
            buf.write(" \(badges)")
            buf.write("\u{1B}[\(textColor)m\(preview)\u{1B}[0m")
        }
    }

    private static func previewLine(item: ListItem, lineIndex: Int, width: Int) -> String {
        if item.sensitive {
            if lineIndex == 0 { return "[sensitive content]" }
            return ""
        }

        let maxWidth = width - 4

        // Enhanced preview for non-text types
        switch item.type {
        case .image:
            return imagePreviewLine(item: item, lineIndex: lineIndex, maxWidth: maxWidth)
        case .filePath:
            return filePreviewLine(item: item, lineIndex: lineIndex, maxWidth: maxWidth)
        case .text:
            break
        }

        // Text: split on literal \n to show multi-line content
        let lines = item.preview.components(separatedBy: "\\n")
        guard lineIndex < lines.count else { return "" }
        let line = lines[lineIndex]
        if line.count > maxWidth {
            return String(line.prefix(maxWidth - 1)) + "\u{2026}"
        }
        return line
    }

    private static func imagePreviewLine(item: ListItem, lineIndex: Int, maxWidth: Int) -> String {
        let sizeStr = formatSize(item.entry.totalSize)
        let dims = imageDimensions(entry: item.entry)

        switch lineIndex {
        case 0:
            let dimsStr = dims.map { "\($0.w) \u{00D7} \($0.h)" } ?? ""
            if dimsStr.isEmpty {
                return "Image \u{2022} \(sizeStr)"
            }
            return "Image \u{2022} \(dimsStr) \u{2022} \(sizeStr)"
        default:
            return ""
        }
    }

    private static func filePreviewLine(item: ListItem, lineIndex: Int, maxWidth: Int) -> String {
        switch lineIndex {
        case 0:
            let sizeStr = formatSize(item.entry.totalSize)
            return "\u{1F4C1}  File \u{2022} \(sizeStr)"
        case 1:
            return item.preview
        default:
            return ""
        }
    }

    private static func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = bytes / 1024
        if kb < 1024 { return "\(kb) KB" }
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.1f MB", mb)
    }

    private static func imageDimensions(entry: ClipEntry) -> (w: Int, h: Int)? {
        let path = entry.filePath
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return nil }

        // Find the image file in bundle
        let imagePath: String
        if isDir.boolValue {
            let manifestPath = (path as NSString).appendingPathComponent("manifest.json")
            guard let data = fm.contents(atPath: manifestPath),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return nil }
            let imgItem = manifest.first { ($0["uti"] ?? "").contains("png") || ($0["uti"] ?? "").contains("tiff") }
            guard let filename = imgItem?["file"] else { return nil }
            imagePath = (path as NSString).appendingPathComponent(filename)
        } else {
            imagePath = path
        }

        guard let data = fm.contents(atPath: imagePath) else { return nil }

        // PNG: width at offset 16, height at offset 20 (big-endian uint32)
        if data.count > 24, data[0] == 0x89, data[1] == 0x50 {
            let w = data.subdata(in: 16..<20).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let h = data.subdata(in: 20..<24).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            return (w: Int(w), h: Int(h))
        }

        // TIFF: just report from file size
        return nil
    }
}
