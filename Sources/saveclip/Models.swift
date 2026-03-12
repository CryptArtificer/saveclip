import Foundation

enum ClipType: String {
    case text
    case image
    case filePath = "filepath"
}

struct ClipEntry {
    let id: Int64
    let timestamp: Date
    let type: ClipType
    let hash: String
    let preview: String
    let filePath: String
    let sourceApp: String?
    let pinned: Bool
    let branch: String
    let sensitive: Bool
    let totalSize: Int
    let copyCount: Int
}

enum BranchState {
    static let defaultBranch = "main"
    static let filePath = Config.defaultDir + "/active_branch"

    static func current() -> String {
        guard let contents = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return defaultBranch
        }
        let name = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? defaultBranch : name
    }

    static func set(_ name: String) {
        let branch = name.isEmpty ? defaultBranch : name
        try? branch.write(toFile: filePath, atomically: true, encoding: .utf8)
    }
}
