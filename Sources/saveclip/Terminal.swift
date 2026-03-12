import Foundation

// MARK: - Key

enum Key: Equatable {
    case char(Character)
    case ctrl(Character)
    case alt(Character)
    case enter
    case escape
    case up, down, left, right
    case pageUp, pageDown
    case home, end
    case backspace
    case delete
    case tab
}

// MARK: - ANSIBuffer

struct ANSIBuffer {
    private var buf: String = ""

    mutating func moveTo(row: Int, col: Int) {
        buf += "\u{1B}[\(row);\(col)H"
    }

    mutating func clearLine() {
        buf += "\u{1B}[2K"
    }

    mutating func clearToEnd() {
        buf += "\u{1B}[K"
    }

    mutating func write(_ s: String) {
        buf += s
    }

    mutating func style(_ code: String) {
        buf += "\u{1B}[\(code)m"
    }

    mutating func reset() {
        buf += "\u{1B}[0m"
    }

    mutating func hideCursor() {
        buf += "\u{1B}[?25l"
    }

    mutating func showCursor() {
        buf += "\u{1B}[?25h"
    }

    func flush() {
        guard !buf.isEmpty else { return }
        FileHandle.standardError.write(buf.data(using: .utf8)!)
    }
}

// MARK: - Terminal

struct Terminal {
    private static var originalTermios: termios?

    static func enableRawMode() {
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        originalTermios = raw
        raw.c_lflag &= ~UInt(ECHO | ICANON | ISIG | IEXTEN)
        raw.c_iflag &= ~UInt(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
        raw.c_oflag &= ~UInt(OPOST)
        raw.c_cc.16 = 0  // VMIN
        raw.c_cc.17 = 1  // VTIME = 100ms
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    }

    static func disableRawMode() {
        if var orig = originalTermios {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &orig)
            originalTermios = nil
        }
    }

    static func size() -> (cols: Int, rows: Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == -1 {
            // Try stderr (stdout might be piped)
            if ioctl(STDERR_FILENO, TIOCGWINSZ, &ws) == -1 {
                return (cols: 80, rows: 24)
            }
        }
        return (cols: Int(ws.ws_col), rows: Int(ws.ws_row))
    }

    static func isTTY() -> Bool {
        return isatty(STDIN_FILENO) != 0
    }

    /// Read a key from stdin. Returns nil on timeout / no input.
    static func readKey() -> Key? {
        var c: UInt8 = 0
        let n = read(STDIN_FILENO, &c, 1)
        guard n == 1 else { return nil }

        // Ctrl keys
        if c == 13 { return .enter }
        if c == 27 { return readEscapeSequence() }
        if c == 127 { return .backspace }
        if c == 9 { return .tab }
        if c < 32 {
            // ctrl-a..ctrl-z
            let ch = Character(UnicodeScalar(c + 96))
            return .ctrl(ch)
        }

        // UTF-8 multi-byte
        if c >= 0x80 {
            return readUTF8(firstByte: c)
        }

        return .char(Character(UnicodeScalar(c)))
    }

    private static func readEscapeSequence() -> Key {
        var seq: [UInt8] = [0, 0]
        if read(STDIN_FILENO, &seq[0], 1) != 1 { return .escape }

        // Alt+char
        if seq[0] != 91 && seq[0] != 79 {
            return .alt(Character(UnicodeScalar(seq[0])))
        }

        if read(STDIN_FILENO, &seq[1], 1) != 1 { return .escape }

        if seq[0] == 91 { // ESC [
            switch seq[1] {
            case 65: return .up
            case 66: return .down
            case 67: return .right
            case 68: return .left
            case 72: return .home
            case 70: return .end
            case 51: // ESC [ 3 ~  = delete
                var tilde: UInt8 = 0
                _ = read(STDIN_FILENO, &tilde, 1)
                return .delete
            case 53: // ESC [ 5 ~  = page up
                var tilde: UInt8 = 0
                _ = read(STDIN_FILENO, &tilde, 1)
                return .pageUp
            case 54: // ESC [ 6 ~  = page down
                var tilde: UInt8 = 0
                _ = read(STDIN_FILENO, &tilde, 1)
                return .pageDown
            case 49: // ESC [ 1 ; ...  or ESC [ 1 ~
                var next: UInt8 = 0
                _ = read(STDIN_FILENO, &next, 1)
                if next == 126 { return .home } // ESC [ 1 ~
                // Skip modifier sequences like ESC [ 1 ; 5 A
                if next == 59 {
                    var mod: UInt8 = 0
                    _ = read(STDIN_FILENO, &mod, 1)
                    var final: UInt8 = 0
                    _ = read(STDIN_FILENO, &final, 1)
                    switch final {
                    case 65: return .up
                    case 66: return .down
                    case 67: return .right
                    case 68: return .left
                    default: return .escape
                    }
                }
                return .escape
            case 52: // ESC [ 4 ~  = end
                var tilde: UInt8 = 0
                _ = read(STDIN_FILENO, &tilde, 1)
                return .end
            default:
                return .escape
            }
        }

        if seq[0] == 79 { // ESC O
            switch seq[1] {
            case 72: return .home
            case 70: return .end
            default: return .escape
            }
        }

        return .escape
    }

    private static func readUTF8(firstByte: UInt8) -> Key {
        var bytes: [UInt8] = [firstByte]
        let expectedLen: Int
        if firstByte & 0xE0 == 0xC0 { expectedLen = 2 }
        else if firstByte & 0xF0 == 0xE0 { expectedLen = 3 }
        else if firstByte & 0xF8 == 0xF0 { expectedLen = 4 }
        else { return .char("?") }

        for _ in 1..<expectedLen {
            var b: UInt8 = 0
            guard read(STDIN_FILENO, &b, 1) == 1 else { break }
            bytes.append(b)
        }

        if let str = String(bytes: bytes, encoding: .utf8), let ch = str.first {
            return .char(ch)
        }
        return .char("?")
    }
}

// MARK: - Region (partial-height screen claim)

final class Region {
    let height: Int
    let startRow: Int
    private let totalRows: Int

    init(height: Int) {
        let (_, rows) = Terminal.size()
        self.totalRows = rows
        self.height = min(height, rows)

        // Print blank lines to push terminal content up
        var buf = ANSIBuffer()
        for _ in 0..<self.height {
            buf.write("\n")
        }
        buf.flush()

        // Our region is the bottom `height` rows
        self.startRow = rows - self.height + 1
    }

    func release() {
        var buf = ANSIBuffer()
        // Clear our region
        for row in startRow...(startRow + height - 1) {
            buf.moveTo(row: row, col: 1)
            buf.clearLine()
        }
        // Move cursor to the start of our region
        buf.moveTo(row: startRow, col: 1)
        buf.showCursor()
        buf.flush()
    }
}
