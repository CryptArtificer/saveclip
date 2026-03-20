import Foundation
import Testing
@testable import SaveClipLib

struct StorageTests {
    private func makeTextContent(_ text: String) -> ClipContent {
        let data = text.data(using: .utf8)!
        let rep = ClipRepresentation(uti: "public.utf8-plain-text", data: data, filename: "text.txt")
        let preview = String(text.prefix(5000)).replacingOccurrences(of: "\n", with: "\\n")
        return ClipContent(representations: [rep], preview: preview, primaryType: .text, totalSize: data.count)
    }

    private func freshStorage() throws -> Storage {
        let path = NSTemporaryDirectory() + "saveclip-test-\(UUID().uuidString).db"
        return try Storage(config: Config.load(), dbPath: path)
    }

    @Test func saveAndGet() throws {
        let storage = try freshStorage()
        let content = makeTextContent("test-save-\(UUID().uuidString)")
        let entry = try storage.save(content: content, preview: content.preview, sourceApp: "test", branch: "main")
        let fetched = storage.get(id: entry.id)
        #expect(fetched != nil)
        #expect(fetched?.preview == content.preview)
        #expect(fetched?.branch == "main")
        #expect(fetched?.sourceApp == "test")
        try storage.delete(id: entry.id)
    }

    @Test func listReturnsRecentFirst() throws {
        let storage = try freshStorage()
        let tag = UUID().uuidString
        let e1 = try storage.save(content: makeTextContent("first-\(tag)"), preview: "first-\(tag)", sourceApp: nil, branch: "main")
        let e2 = try storage.save(content: makeTextContent("second-\(tag)"), preview: "second-\(tag)", sourceApp: nil, branch: "main")
        let e3 = try storage.save(content: makeTextContent("third-\(tag)"), preview: "third-\(tag)", sourceApp: nil, branch: "main")
        let entries = storage.list(limit: 3)
        #expect(entries[0].id >= entries[1].id)
        try storage.delete(id: e1.id)
        try storage.delete(id: e2.id)
        try storage.delete(id: e3.id)
    }

    @Test func listFiltersByBranch() throws {
        let storage = try freshStorage()
        let tag = UUID().uuidString
        let e1 = try storage.save(content: makeTextContent("work-\(tag)"), preview: "work-\(tag)", sourceApp: nil, branch: "test-branch-\(tag)")
        let e2 = try storage.save(content: makeTextContent("other-\(tag)"), preview: "other-\(tag)", sourceApp: nil, branch: "main")
        let branchEntries = storage.list(limit: 100, branch: "test-branch-\(tag)")
        #expect(branchEntries.contains { $0.id == e1.id })
        #expect(!branchEntries.contains { $0.id == e2.id })
        try storage.delete(id: e1.id)
        try storage.delete(id: e2.id)
    }

    @Test func deleteRemovesEntry() throws {
        let storage = try freshStorage()
        let content = makeTextContent("delete-\(UUID().uuidString)")
        let entry = try storage.save(content: content, preview: content.preview, sourceApp: nil, branch: "main")
        try storage.delete(id: entry.id)
        #expect(storage.get(id: entry.id) == nil)
    }

    @Test func pinAndUnpin() throws {
        let storage = try freshStorage()
        let content = makeTextContent("pin-\(UUID().uuidString)")
        let entry = try storage.save(content: content, preview: content.preview, sourceApp: nil, branch: "main")
        #expect(storage.get(id: entry.id)!.pinned == false)
        try storage.pin(id: entry.id)
        #expect(storage.get(id: entry.id)!.pinned == true)
        try storage.unpin(id: entry.id)
        #expect(storage.get(id: entry.id)!.pinned == false)
        try storage.delete(id: entry.id)
    }

    @Test func moveToBranch() throws {
        let storage = try freshStorage()
        let content = makeTextContent("move-\(UUID().uuidString)")
        let entry = try storage.save(content: content, preview: content.preview, sourceApp: nil, branch: "main")
        try storage.moveToBranch(id: entry.id, branch: "work")
        #expect(storage.get(id: entry.id)?.branch == "work")
        try storage.delete(id: entry.id)
    }

    @Test func bumpToFront() throws {
        let storage = try freshStorage()
        let content = makeTextContent("bump-\(UUID().uuidString)")
        let entry = try storage.save(content: content, preview: content.preview, sourceApp: nil, branch: "main")
        let ts = entry.timestamp
        Thread.sleep(forTimeInterval: 0.01)
        try storage.bumpToFront(id: entry.id)
        let updated = storage.get(id: entry.id)!
        #expect(updated.timestamp > ts)
        #expect(updated.copyCount == 2)
        try storage.delete(id: entry.id)
    }

    @Test func searchFTS5() throws {
        let storage = try freshStorage()
        let tag = UUID().uuidString
        let e1 = try storage.save(content: makeTextContent("quickfox-\(tag) jumps"), preview: "quickfox-\(tag) jumps", sourceApp: nil, branch: "main")
        let e2 = try storage.save(content: makeTextContent("lazy-\(tag) dog"), preview: "lazy-\(tag) dog", sourceApp: nil, branch: "main")
        let results = storage.search(query: "quickfox-\(tag)", limit: 10)
        #expect(results.count == 1)
        #expect(results[0].preview.contains("quickfox"))
        try storage.delete(id: e1.id)
        try storage.delete(id: e2.id)
    }

    @Test func fuzzyFallbackFindsTypos() throws {
        let storage = try freshStorage()
        let e = try storage.save(content: makeTextContent("cutlass sword"), preview: "cutlass sword", sourceApp: nil, branch: "main")
        let results = storage.fuzzyFallback(query: "cultass", limit: 200)
        #expect(results.count >= 1)
        try storage.delete(id: e.id)
    }

    @Test func markSensitive() throws {
        let storage = try freshStorage()
        let content = makeTextContent("secret-\(UUID().uuidString)")
        let entry = try storage.save(content: content, preview: content.preview, sourceApp: nil, branch: "main")
        #expect(storage.get(id: entry.id)!.sensitive == false)
        try storage.markSensitive(id: entry.id)
        #expect(storage.get(id: entry.id)!.sensitive == true)
        try storage.delete(id: entry.id)
    }

    @Test func sqlInjectionSafe() throws {
        let storage = try freshStorage()
        let content = makeTextContent("injection-\(UUID().uuidString)")
        let entry = try storage.save(content: content, preview: content.preview, sourceApp: nil, branch: "main")
        let evilBranch = "test'; DROP TABLE clips; --"
        try storage.moveToBranch(id: entry.id, branch: evilBranch)
        #expect(storage.get(id: entry.id)?.branch == evilBranch)
        #expect(storage.entryCount() > 0)
        try storage.delete(id: entry.id)
    }
}
