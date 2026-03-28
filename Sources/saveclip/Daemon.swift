import AppKit
import Foundation

final class Daemon {
    static let pidPath = Config.defaultDir + "/saveclip.pid"
    static let logPath = Config.defaultDir + "/saveclip.log"

    static func start(foreground: Bool = false) throws {
        if let pid = runningPID() {
            print("saveclip is already running (PID \(pid))")
            return
        }

        if foreground {
            try runLoop()
        } else {
            try launchDetached()
            // Give it a moment to start
            Thread.sleep(forTimeInterval: 0.5)
            if let pid = runningPID() {
                print("saveclip started (PID \(pid))")
            } else {
                print("saveclip failed to start. Check \(logPath)")
            }
        }
    }

    static func stop() {
        guard let pid = runningPID() else {
            print("saveclip is not running")
            return
        }
        kill(pid, SIGTERM)
        try? FileManager.default.removeItem(atPath: pidPath)
        print("saveclip stopped (PID \(pid))")
    }

    static func status() {
        if let pid = runningPID() {
            print("saveclip is running (PID \(pid))")
        } else {
            print("saveclip is not running")
        }
    }

    // MARK: - Private

    private static func launchDetached() throws {
        let config = Config.load()
        try config.ensureDirectories()

        let execURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let process = Process()
        process.executableURL = execURL
        process.arguments = ["_daemon"]
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        // Redirect stdout/stderr to log file
        let logFile = FileHandle(forWritingAtPath: logPath) ?? {
            FileManager.default.createFile(atPath: logPath, contents: nil)
            return FileHandle(forWritingAtPath: logPath)!
        }()
        logFile.seekToEndOfFile()
        process.standardOutput = logFile
        process.standardError = logFile
        process.standardInput = FileHandle.nullDevice

        // Detach from terminal
        process.qualityOfService = .utility

        try process.run()
    }

    private static func rotateLogs() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: logPath),
              let attrs = try? fm.attributesOfItem(atPath: logPath),
              let size = attrs[.size] as? Int64,
              size > 5 * 1024 * 1024 else { return }

        let backupPath = logPath + ".1"
        try? fm.removeItem(atPath: backupPath)
        try? fm.moveItem(atPath: logPath, toPath: backupPath)
        fm.createFile(atPath: logPath, contents: nil)
    }

    static func runLoop() throws {
        let config = Config.load()
        try config.ensureDirectories()
        rotateLogs()

        // Write PID file
        let pid = ProcessInfo.processInfo.processIdentifier
        try "\(pid)".write(toFile: pidPath, atomically: true, encoding: .utf8)

        // Handle signals for clean shutdown
        let sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signal(SIGTERM, SIG_IGN)
        sigTermSource.setEventHandler {
            cleanup()
            exit(0)
        }
        sigTermSource.resume()

        let sigIntSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        sigIntSource.setEventHandler {
            cleanup()
            exit(0)
        }
        sigIntSource.resume()

        let storage = try Storage(config: config)
        let monitor = ClipboardMonitor()

        log("saveclip daemon started (PID \(pid), polling every \(config.pollInterval)s)")

        // We need a RunLoop for NSPasteboard to work properly
        let timer = Timer(timeInterval: config.pollInterval, repeats: true) { _ in
            guard monitor.hasChanged() else { return }

            // Skip if placed by `add` command
            if NSPasteboard.general.data(forType: Add.skipMarkerType) != nil {
                return
            }

            guard let content = monitor.currentContent() else { return }

            // Check size limit
            guard content.totalSize <= config.maxEntrySize else {
                log("Skipping entry: too large (\(content.totalSize) bytes)")
                return
            }

            let hash = content.combinedHash

            // Check dedup
            if storage.isDuplicate(hash: hash) {
                return
            }

            // Check excluded apps
            let sourceApp = monitor.frontmostApp()
            if let app = sourceApp, config.excludedApps.contains(app) {
                log("Skipping entry from excluded app: \(app)")
                return
            }

            // Flag sensitive content
            let sensitive = content.primaryType == .text && config.isSensitive(content.preview)

            // Resolve branch: heuristic rules first, then active branch
            let branch = config.resolveBranch(sourceApp: sourceApp) ?? BranchState.current()

            do {
                let entry = try storage.save(
                    content: content,
                    preview: content.preview,
                    sourceApp: sourceApp,
                    branch: branch,
                    sensitive: sensitive
                )
                let branchTag = branch == "main" ? "" : " [\(branch)]"
                log("Saved \(entry.type.rawValue) (\(content.representations.count) reps, \(content.totalSize / 1024)KB)\(branchTag): \(entry.preview)")
            } catch {
                log("Error saving clip: \(error)")
            }
        }

        RunLoop.main.add(timer, forMode: .default)

        // Run maintenance (compress old clips, expire TTL) every hour
        let maintenanceTimer = Timer(timeInterval: 3600, repeats: true) { _ in
            log("Running maintenance...")
            storage.runMaintenance()
        }
        RunLoop.main.add(maintenanceTimer, forMode: .default)
        // Run once at startup too
        storage.runMaintenance()

        RunLoop.main.run()
    }

    private static func cleanup() {
        try? FileManager.default.removeItem(atPath: pidPath)
        log("saveclip daemon stopped")
    }

    static func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(message)"
        print(line)
    }

    static func runningPID() -> pid_t? {
        guard let pidStr = try? String(contentsOfFile: pidPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = pid_t(pidStr) else {
            return nil
        }

        // Check if process is actually alive
        if kill(pid, 0) == 0 {
            return pid
        } else {
            // Stale PID file
            try? FileManager.default.removeItem(atPath: pidPath)
            return nil
        }
    }
}
