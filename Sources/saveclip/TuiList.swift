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
        let modeLabel = state.viewMode.label
        let countLabel = "\(state.filteredItems.count)/\(state.allItems.count)"
        buf.style("1;36") // bold cyan
        buf.write(" \(modeLabel)")
        buf.reset()
        buf.style("2") // dim
        buf.write(" \(countLabel)")
        buf.reset()

        if state.unsafeMode {
            buf.write(" ")
            buf.style("1;31") // bold red
            buf.write(" UNSAFE ")
            buf.reset()
        }

        // Keybind hints (right-aligned)
        let hints: String
        if let msg = state.message {
            hints = " \(msg) "
        } else {
            hints = "enter=copy  ^O=stdout  ^D=del  ^P=pin  ^U=unsafe"
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

        // ── List (bottom-up: selected near prompt) ──
        for i in 0..<listRows {
            buf.moveTo(row: row, col: 1)
            buf.clearLine()
            // Render in reverse: row 0 (top) shows the furthest item, last row shows selected
            let visualIndex = listRows - 1 - i
            let idx = state.scrollOffset + visualIndex
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

    /// 256-color heat based on age (logarithmic bands)
    private static func heatColor(for item: ListItem) -> Int {
        let age = -item.entry.timestamp.timeIntervalSinceNow
        if age < 3600        { return 196 }  // < 1h   bright red (hot)
        if age < 6 * 3600    { return 208 }  // < 6h   orange
        if age < 86400       { return 220 }  // < 1d   yellow
        if age < 3 * 86400   { return 40  }  // < 3d   green
        if age < 7 * 86400   { return 44  }  // < 1w   cyan
        if age < 30 * 86400  { return 33  }  // < 1mo  blue
        if age < 90 * 86400  { return 61  }  // < 3mo  dim purple
        return 242                            // older  gray (cold)
    }

    private static func renderListItem(buf: inout ANSIBuffer, item: ListItem, selected: Bool, width: Int) {
        let marker = selected ? "\u{25B8} " : "  "
        let idStr = String(item.id)
        let ageStr = item.age.padding(toLength: 4, withPad: " ", startingAt: 0)
        let pin = item.pinned ? "*" : " "
        let freq = item.copyCount > 1 ? "×\(item.copyCount) " : ""
        let branch = item.branch != "main" ? "[\(item.branch)] " : ""
        let heat = heatColor(for: item)

        // Calculate available width for preview
        let metaWidth = marker.count + idStr.count + 1 + ageStr.count + 1 + pin.count + 1 + freq.count + branch.count
        let maxPreview = max(10, width - metaWidth - 1)

        var preview = item.preview
        if preview.hasSuffix("\\n") { preview = String(preview.dropLast(2)) }
        preview = preview.replacingOccurrences(of: "\\n", with: " ")

        if item.sensitive {
            let visible = String(preview.prefix(8))
            let masked = String(repeating: "•", count: min(max(0, preview.count - 8), 20))
            preview = "[sensitive] \(visible)\(masked)"
        }

        preview = String(preview.prefix(maxPreview))

        if selected {
            // Selected: inverse with heat-colored background
            buf.write("\u{1B}[1;7;38;5;\(heat)m")
            buf.write(marker)
            buf.write("\u{1B}[2;7;38;5;\(heat)m")
            buf.write(idStr)
            buf.write(" ")
            buf.write(ageStr)
            buf.write("\u{1B}[1;7;38;5;\(heat)m")
            buf.write(" ")
            if item.pinned {
                buf.write("\u{1B}[33;7m")
                buf.write(pin)
                buf.write("\u{1B}[1;7;38;5;\(heat)m")
            } else {
                buf.write(pin)
            }
            buf.write(" ")
            if !freq.isEmpty {
                buf.write("\u{1B}[36;7m")
                buf.write(freq)
                buf.write("\u{1B}[1;7;38;5;\(heat)m")
            }
            if !branch.isEmpty {
                buf.write("\u{1B}[35;7m")
                buf.write(branch)
                buf.write("\u{1B}[1;7;38;5;\(heat)m")
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
                buf.style("33")
                buf.write(pin)
                buf.reset()
            } else {
                buf.write(pin)
            }
            buf.write(" ")
            if !freq.isEmpty {
                buf.style("36")
                buf.write(freq)
                buf.reset()
            }
            if !branch.isEmpty {
                buf.style("35")
                buf.write(branch)
                buf.reset()
            }
            if item.sensitive {
                buf.write("\u{1B}[31m")
                buf.write(preview)
                buf.reset()
            } else {
                // Heat-colored preview text
                buf.write("\u{1B}[38;5;\(heat)m")
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
            let dimsStr = dims.map { "\($0.w)\u{00D7}\($0.h)" } ?? "unknown size"
            return "\u{1F5BC}  Image \u{2022} \(dimsStr) \u{2022} \(sizeStr)"
        case 1:
            if let d = dims {
                // Mini ASCII thumbnail hint
                let aspect = Double(d.w) / Double(d.h)
                let barW = min(max(Int(aspect * 6), 2), 20)
                let border = String(repeating: "\u{2591}", count: barW)
                return "\u{250C}\(border)\u{2510}  \(item.entry.sourceApp ?? "")"
            }
            return item.entry.sourceApp ?? ""
        case 2:
            if let d = dims {
                let aspect = Double(d.w) / Double(d.h)
                let barW = min(max(Int(aspect * 6), 2), 20)
                let border = String(repeating: "\u{2591}", count: barW)
                return "\u{2514}\(border)\u{2518}"
            }
            return ""
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
