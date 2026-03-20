import Foundation
import Testing
@testable import SaveClipLib

struct TruncateANSITests {
    @Test func plainTextTruncation() {
        let result = ListRenderer.truncateANSI("hello world", maxWidth: 5)
        #expect(result.hasPrefix("hello"))
        #expect(result.hasSuffix("\u{1B}[0m"))
    }

    @Test func preservesANSICodes() {
        let input = "\u{1B}[31mred text\u{1B}[0m"
        let result = ListRenderer.truncateANSI(input, maxWidth: 3)
        #expect(result.contains("red"))
        #expect(result.hasSuffix("\u{1B}[0m"))
        #expect(!result.contains("text"))
    }

    @Test func emptyString() {
        let result = ListRenderer.truncateANSI("", maxWidth: 10)
        #expect(result == "\u{1B}[0m")
    }

    @Test func widthZero() {
        let result = ListRenderer.truncateANSI("hello", maxWidth: 0)
        #expect(result == "\u{1B}[0m")
    }

    @Test func ansiCodesNotCounted() {
        let input = "\u{1B}[38;5;75mhello\u{1B}[0m world"
        let result = ListRenderer.truncateANSI(input, maxWidth: 8)
        #expect(result.contains("hello"))
        #expect(result.contains("wo"))
        #expect(!result.contains("world"))
    }
}

struct FormatSizeTests {
    @Test func bytes() {
        #expect(ListRenderer.formatSize(500) == "500 B")
    }

    @Test func kilobytes() {
        #expect(ListRenderer.formatSize(2048) == "2 KB")
    }

    @Test func megabytes() {
        #expect(ListRenderer.formatSize(1_500_000) == "1.4 MB")
    }
}
