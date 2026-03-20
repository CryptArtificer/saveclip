import Foundation
import Testing
@testable import SaveClipLib

struct LevenshteinTests {
    private func freshStorage() throws -> Storage {
        let path = NSTemporaryDirectory() + "saveclip-test-\(UUID().uuidString).db"
        return try Storage(config: Config.load(), dbPath: path)
    }

    private func save(_ storage: Storage, _ text: String) throws -> ClipEntry {
        let data = text.data(using: .utf8)!
        let rep = ClipRepresentation(uti: "public.utf8-plain-text", data: data, filename: "text.txt")
        let content = ClipContent(representations: [rep], preview: text, primaryType: .text, totalSize: data.count)
        return try storage.save(content: content, preview: text, sourceApp: nil, branch: "main")
    }

    @Test func exactMatch() throws {
        let storage = try freshStorage()
        _ = try save(storage, "hello world")
        let results = storage.fuzzyFallback(query: "hello", limit: 200)
        #expect(results.count >= 1)
    }

    @Test func singleCharDifference() throws {
        let storage = try freshStorage()
        _ = try save(storage, "kitten plays")
        // "kiten" → "kitten" distance 1
        let results = storage.fuzzyFallback(query: "kiten", limit: 200)
        #expect(results.count >= 1)
    }

    @Test func transposedChars() throws {
        let storage = try freshStorage()
        _ = try save(storage, "cutlass sword")
        // "cultass" → "cutlass" distance 2
        let results = storage.fuzzyFallback(query: "cultass", limit: 200)
        #expect(results.count >= 1)
    }

    @Test func tooDistantNoMatch() throws {
        let storage = try freshStorage()
        _ = try save(storage, "abcdef stuff")
        // "xyz" vs any word — too distant
        let results = storage.fuzzyFallback(query: "xyz", limit: 200)
        #expect(results.isEmpty)
    }
}
