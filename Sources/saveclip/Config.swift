import Foundation

struct Config {
    var storageDir: String
    var pollInterval: TimeInterval
    var maxEntries: Int
    var maxEntrySize: Int
    var excludedApps: [String]
    var compressAfterDays: Int
    var ttlDays: Int
    var branchRules: [BranchRule]
    var sensitivePatterns: [String]
    var maxStorageMB: Int

    struct BranchRule {
        let app: String
        let branch: String
    }

    static let defaultDir = NSHomeDirectory() + "/.saveclip"
    static let configPath = defaultDir + "/config.toml"

    static func load() -> Config {
        var config = Config(
            storageDir: defaultDir + "/clips",
            pollInterval: 0.5,
            maxEntries: 1000,
            maxEntrySize: 10 * 1024 * 1024,
            excludedApps: [],
            compressAfterDays: 7,
            ttlDays: 90,
            branchRules: [],
            sensitivePatterns: [],
            maxStorageMB: 300
        )

        guard let contents = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return config
        }

        for line in contents.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            switch key {
            case "storage_dir":
                config.storageDir = (value as NSString).expandingTildeInPath
            case "poll_interval":
                if let v = TimeInterval(value) { config.pollInterval = v }
            case "max_entries":
                if let v = Int(value) { config.maxEntries = v }
            case "max_entry_size":
                if let v = Int(value) { config.maxEntrySize = v }
            case "excluded_apps":
                config.excludedApps = value
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            case "compress_after_days":
                if let v = Int(value) { config.compressAfterDays = v }
            case "ttl_days":
                if let v = Int(value) { config.ttlDays = v }
            case "max_storage_mb":
                if let v = Int(value) { config.maxStorageMB = v }
            case "sensitive_patterns":
                config.sensitivePatterns = value
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            case _ where key.hasPrefix("branch."):
                // branch.Slack = "work"  ->  app=Slack, branch=work
                let app = String(key.dropFirst("branch.".count))
                if !app.isEmpty {
                    config.branchRules.append(BranchRule(app: app, branch: value))
                }
            default:
                break
            }
        }

        return config
    }

    func resolveBranch(sourceApp: String?) -> String? {
        guard let app = sourceApp else { return nil }
        for rule in branchRules {
            if app.localizedCaseInsensitiveContains(rule.app) {
                return rule.branch
            }
        }
        return nil
    }

    func ensureDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: Config.defaultDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: storageDir, withIntermediateDirectories: true)
    }
}
