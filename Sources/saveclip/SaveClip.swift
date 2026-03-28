import AppKit
import ArgumentParser
import Foundation
import UniformTypeIdentifiers

private func printEntries(_ entries: [ClipEntry], showBranch: Bool = false) {
    let now = Date()
    let calendar = Calendar.current
    let idWidth = entries.map { String($0.id).count }.max() ?? 1

    let dim = "\u{001B}[2m"
    let reset = "\u{001B}[0m"
    let bold = "\u{001B}[1m"
    let magenta = "\u{001B}[35m"

    for entry in entries {
        let age = relativeTime(from: entry.timestamp, to: now, calendar: calendar)
        let pin = entry.pinned ? " \u{001B}[33m*\(reset)" : " "
        let freq = entry.copyCount > 1 ? " \u{001B}[36m×\(entry.copyCount)\(reset)" : ""

        let typeTag: String
        switch entry.type {
        case .text: typeTag = ""
        case .image: typeTag = "\u{001B}[36m[img]\(reset) "
        case .filePath: typeTag = "\u{001B}[33m[file]\(reset) "
        }

        let branchTag: String
        if showBranch && entry.branch != "main" {
            branchTag = " \(magenta)\(entry.branch)\(reset)"
        } else {
            branchTag = ""
        }

        let idStr = String(entry.id).padding(toLength: idWidth, withPad: " ", startingAt: 0)
        let ageStr = age.padding(toLength: 4, withPad: " ", startingAt: 0)

        var preview = entry.preview
        if preview.hasSuffix("\\n") {
            preview = String(preview.dropLast(2))
        }
        preview = String(preview.prefix(70))

        let red = "\u{001B}[31m"
        if entry.sensitive {
            // Redact in CLI: show first 8 chars + masked remainder
            let visible = String(preview.prefix(8))
            let masked = String(repeating: "•", count: min(preview.count - 8, 20))
            print("\(dim)\(idStr)\(reset)\(pin) \(dim)\(ageStr)\(reset)\(freq)\(branchTag) \(red)[sensitive]\(reset) \(dim)\(visible)\(masked)\(reset)")
        } else {
            print("\(dim)\(idStr)\(reset)\(pin) \(dim)\(ageStr)\(reset)\(freq)\(branchTag) \(typeTag)\(bold)\(preview)\(reset)")
        }
    }
}

func relativeTime(from date: Date, to now: Date, calendar: Calendar) -> String {
    let seconds = Int(now.timeIntervalSince(date))
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }
    let days = hours / 24
    if days < 7 { return "\(days)d" }
    let weeks = days / 7
    if weeks < 52 { return "\(weeks)w" }
    let years = days / 365
    if years < 100 { return "\(years)y" }
    return "old"
}

public struct SaveClip: ParsableCommand {
    public init() {}
    public static let configuration = CommandConfiguration(
        commandName: "saveclip",
        abstract: "Clipboard history manager for macOS",
        discussion: """
            Quick usage:
              saveclip              Print the latest clip to stdout
              echo hi | saveclip    Save stdin (tees to stdout, splits on \\0)
              echo hi | saveclip -s Slurp all stdin as one entry
              echo hi | saveclip -q Save quietly (no tee, no status output)
              saveclip file.png     Add a file to history
              saveclip tui          Interactive fullscreen picker
              saveclip list         List recent entries
              saveclip search foo   Search history
            """,
        subcommands: [Add.self, BranchCmd.self, BranchesCmd.self, Clear.self, ConfigCmd.self, DaemonCmd.self, Delete.self, DeleteMatching.self, Frequent.self, Get.self, List.self, MoveCmd.self, Paste.self, Pin.self, Pop.self, Scrub.self, Search.self, Start.self, Status.self, Stop.self, TuiCommand.self, Unpin.self]
    )

    @Flag(name: .shortAndLong, help: .hidden)
    var slurp = false

    @Flag(name: .shortAndLong, help: .hidden)
    var quiet = false

    public func run() throws {
        if isatty(STDIN_FILENO) == 0 {
            var args: [String] = []
            if slurp { args.append("--slurp") }
            if quiet { args.append("--quiet") }
            let add = try Add.parse(args)
            try add.run()
        } else {
            let paste = try Paste.parse([])
            try paste.run()
        }
    }
}

struct Start: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start the clipboard daemon")

    @Flag(name: .shortAndLong, help: "Run in the foreground")
    var foreground = false

    func run() throws {
        try Daemon.start(foreground: foreground)
    }
}

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop the clipboard daemon")

    func run() {
        Daemon.stop()
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check daemon status")

    func run() {
        Daemon.status()
    }
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List recent clipboard entries")

    @Option(name: .shortAndLong, help: "Number of entries to show")
    var count: Int = 20

    @Option(name: .shortAndLong, help: "Filter by branch")
    var branch: String?

    @Flag(name: .shortAndLong, help: "Show all branches")
    var all = false

    func run() throws {
        let config = Config.load()
        let storage = try Storage(config: config)

        let filterBranch: String? = all ? nil : (branch ?? BranchState.current())
        let showBranch = all || branch == nil
        let entries = storage.list(limit: count, branch: all ? nil : filterBranch)

        if entries.isEmpty {
            let ctx = all ? "" : " on branch \"\(filterBranch ?? "main")\""
            print("No clipboard entries\(ctx).")
            return
        }

        printEntries(entries, showBranch: showBranch)

        let total = storage.entryCount(branch: all ? nil : filterBranch)
        if total > entries.count {
            print("\n\u{001B}[2m\(entries.count) of \(total) entries. Use -c to show more.\u{001B}[0m")
        }
    }
}

struct Get: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Copy a saved entry back to clipboard, or print to stdout")

    @Argument(help: "Entry ID")
    var id: Int64

    @Flag(name: .shortAndLong, help: "Print to stdout instead of copying to clipboard")
    var output = false

    @Flag(name: .shortAndLong, help: "Print the file path of the stored clip")
    var path = false

    func run() throws {
        let config = Config.load()
        let storage = try Storage(config: config)

        guard let entry = storage.get(id: id) else {
            print("Entry \(id) not found")
            throw ExitCode.failure
        }

        if path {
            print(entry.filePath)
            return
        }

        guard let data = storage.readClipData(entry: entry) else {
            print("Clip file missing: \(entry.filePath)")
            throw ExitCode.failure
        }

        if output {
            switch entry.type {
            case .text, .filePath:
                if let str = String(data: data, encoding: .utf8) {
                    print(str, terminator: "")
                }
            case .image:
                FileHandle.standardOutput.write(data)
            }
        } else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()

            // Restore all representations from the bundle
            if let reps = storage.readBundleRepresentations(entry: entry) {
                for rep in reps {
                    pasteboard.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.uti))
                }
            } else {
                // Fallback: single data
                switch entry.type {
                case .text, .filePath:
                    if let str = String(data: data, encoding: .utf8) {
                        pasteboard.setString(str, forType: .string)
                    }
                case .image:
                    pasteboard.setData(data, forType: .png)
                }
            }

            print("Copied entry \(id) to clipboard")
        }
    }
}

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Search clipboard history and act on results")

    @Argument(help: "Search term")
    var query: String

    @Option(name: .shortAndLong, help: "Max results")
    var count: Int = 20

    @Flag(name: .shortAndLong, help: "Search all branches")
    var all = false

    // Actions — at most one
    @Flag(name: .long, help: "Delete all matches")
    var delete = false

    @Flag(name: .long, help: "Pin all matches")
    var pin = false

    @Flag(name: .long, help: "Unpin all matches")
    var unpin = false

    @Flag(name: .long, help: "Copy top match back to clipboard")
    var get = false

    @Option(name: .long, help: "Move all matches to a branch")
    var moveTo: String?

    func run() throws {
        let config = Config.load()
        let storage = try Storage(config: config)
        let filterBranch: String? = all ? nil : BranchState.current()
        let entries = storage.search(query: query, limit: count, branch: filterBranch)

        if entries.isEmpty {
            print("No matches for \"\(query)\"")
            return
        }

        // --get: copy the most recent match to clipboard
        if get {
            let entry = entries[0]
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()

            if let reps = storage.readBundleRepresentations(entry: entry) {
                for rep in reps {
                    pasteboard.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.uti))
                }
            } else {
                guard let data = storage.readClipData(entry: entry) else {
                    print("Clip file missing: \(entry.filePath)")
                    throw ExitCode.failure
                }
                switch entry.type {
                case .text, .filePath:
                    if let str = String(data: data, encoding: .utf8) {
                        pasteboard.setString(str, forType: .string)
                    }
                case .image:
                    pasteboard.setData(data, forType: .png)
                }
            }
            print("Copied entry \(entry.id) to clipboard")
            return
        }

        // --delete: remove all matches
        if delete {
            for entry in entries {
                try storage.delete(id: entry.id)
            }
            print("Deleted \(entries.count) entries matching \"\(query)\"")
            return
        }

        // --pin / --unpin
        if pin {
            for entry in entries {
                try storage.pin(id: entry.id)
            }
            print("Pinned \(entries.count) entries matching \"\(query)\"")
            return
        }
        if unpin {
            for entry in entries {
                try storage.unpin(id: entry.id)
            }
            print("Unpinned \(entries.count) entries matching \"\(query)\"")
            return
        }

        // --move-to: move all matches to a branch
        if let branch = moveTo {
            for entry in entries {
                try storage.moveToBranch(id: entry.id, branch: branch)
            }
            print("Moved \(entries.count) entries to branch \"\(branch)\"")
            return
        }

        // Default: just list them
        printEntries(entries, showBranch: all)
        print("\n\u{001B}[2m\(entries.count) match(es)\u{001B}[0m")
    }
}

struct Paste: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "paste",
        abstract: "Print clipboard entries to stdout"
    )

    @Option(name: .shortAndLong, help: "Number of entries to print")
    var count: Int = 1

    @Flag(name: [.customShort("0"), .customLong("null")], help: "Null byte separator between entries")
    var zero = false

    func run() throws {
        let config = Config.load()
        let storage = try Storage(config: config)
        let entries = storage.list(limit: count)

        if entries.isEmpty {
            FileHandle.standardError.write("No clipboard entries.\n".data(using: .utf8)!)
            throw ExitCode.failure
        }

        let out = FileHandle.standardOutput
        var first = true
        for entry in entries {
            guard entry.type == .text || entry.type == .filePath else {
                if count == 1 {
                    FileHandle.standardError.write("Entry \(entry.id) is \(entry.type.rawValue), not text.\n".data(using: .utf8)!)
                    throw ExitCode.failure
                }
                continue
            }
            guard let data = storage.readClipData(entry: entry),
                  let str = String(data: data, encoding: .utf8) else {
                if count == 1 {
                    FileHandle.standardError.write("Clip file missing.\n".data(using: .utf8)!)
                    throw ExitCode.failure
                }
                continue
            }

            if !first {
                let sep = zero ? "\0" : "\n\n"
                out.write(sep.data(using: .utf8)!)
            }
            out.write(str.data(using: .utf8)!)
            first = false
        }
    }
}

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add text from stdin or files to clipboard history"
    )

    @Flag(name: .shortAndLong, help: "Slurp all input as one entry (ignore null delimiters)")
    var slurp = false

    @Flag(name: .shortAndLong, help: "Suppress output (no tee, no status messages)")
    var quiet = false

    @Argument(help: "Files to add (omit to read from stdin)")
    var files: [String] = []

    func run() throws {
        let config = Config.load()
        if !files.isEmpty {
            let storage = try Storage(config: config)
            let branch = BranchState.current()
            try addFiles(storage: storage, config: config, branch: branch)
        } else {
            let storage = try Storage(config: config)
            let branch = BranchState.current()
            try addStdin(storage: storage, config: config, branch: branch)
        }
    }

    private func addStdin(storage: Storage, config: Config, branch: String) throws {
        let inputData = FileHandle.standardInput.readDataToEndOfFile()
        guard !inputData.isEmpty,
              let input = String(data: inputData, encoding: .utf8) else {
            FileHandle.standardError.write("No input on stdin.\n".data(using: .utf8)!)
            throw ExitCode.failure
        }

        if slurp {
            var text = input
            if text.hasSuffix("\n") { text = String(text.dropLast()) }
            try saveText(text, storage: storage, config: config, branch: branch)
        } else {
            let parts = input.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
            for var part in parts {
                if part.hasSuffix("\n") { part = String(part.dropLast()) }
                try saveText(part, storage: storage, config: config, branch: branch)
            }
        }

        // Tee: pass through raw input so saveclip works mid-pipeline
        if !quiet {
            FileHandle.standardOutput.write(inputData)
        }
    }

    private static let maxFiles = 20

    private func addFiles(storage: Storage, config: Config, branch: String) throws {
        let fm = FileManager.default

        guard files.count <= Self.maxFiles else {
            FileHandle.standardError.write("Too many files (\(files.count)). Max \(Self.maxFiles) at a time.\n".data(using: .utf8)!)
            throw ExitCode.failure
        }

        for path in files {
            let absPath = path.hasPrefix("/") ? path : fm.currentDirectoryPath + "/" + path
            guard fm.fileExists(atPath: absPath) else {
                FileHandle.standardError.write("File not found: \(path)\n".data(using: .utf8)!)
                continue
            }
            let url = URL(fileURLWithPath: absPath)
            let data = try Data(contentsOf: url)
            let ext = url.pathExtension.lowercased()

            let utType = UTType(filenameExtension: ext) ?? .data
            let uti = utType.identifier

            var reps: [ClipRepresentation] = []
            reps.append(ClipRepresentation(uti: "public.file-url", data: url.absoluteString.data(using: .utf8)!, filename: "fileurl.txt"))
            reps.append(ClipRepresentation(uti: uti, data: data, filename: ClipboardMonitor.filename(for: uti)))

            let clipType: ClipType = utType.conforms(to: .image) ? .image : utType.conforms(to: .text) || utType.conforms(to: .sourceCode) ? .text : .filePath
            let preview: String
            if clipType == .text, let text = String(data: data, encoding: .utf8) {
                preview = String(text.prefix(5000)).replacingOccurrences(of: "\n", with: "\\n")
            } else {
                let desc = utType.localizedDescription ?? (ext.isEmpty ? "file" : ext)
                preview = "[\(desc) \(data.count / 1024)KB] \(url.lastPathComponent)"
            }

            let content = ClipContent(representations: reps, preview: preview, primaryType: clipType, totalSize: data.count)
            let entry = try storage.save(content: content, preview: preview, sourceApp: "cli", branch: branch, sensitive: config.isSensitive(preview))

            // Copy to system clipboard with skip marker
            copyToPasteboard(reps, skip: true)

            if !quiet {
                FileHandle.standardError.write("Added \(url.lastPathComponent) (\(ListRenderer.formatSize(data.count)), \(clipType.rawValue)) id=\(entry.id)\n".data(using: .utf8)!)
            }
        }
    }

    private func saveText(_ text: String, storage: Storage, config: Config, branch: String) throws {
        guard !text.isEmpty else { return }
        let data = text.data(using: .utf8)!
        let rep = ClipRepresentation(uti: "public.utf8-plain-text", data: data, filename: "text.txt")
        let preview = String(text.prefix(5000)).replacingOccurrences(of: "\n", with: "\\n")
        let content = ClipContent(representations: [rep], preview: preview, primaryType: .text, totalSize: data.count)
        let sensitive = config.isSensitive(preview)
        try storage.save(content: content, preview: preview, sourceApp: "cli", branch: branch, sensitive: sensitive)

        // Put on system clipboard with skip marker so daemon doesn't re-capture
        copyToPasteboard([rep], skip: true)
    }

    static let skipMarkerType = NSPasteboard.PasteboardType("com.saveclip.already-saved")

    private func copyToPasteboard(_ reps: [ClipRepresentation], skip: Bool = false) {
        let pasteboard = NSPasteboard.general
        let item = NSPasteboardItem()
        for rep in reps {
            item.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.uti))
        }
        if skip {
            item.setData(Data(), forType: Self.skipMarkerType)
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }
}

struct Pop: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pop",
        abstract: "Print the most recent entry to stdout and remove it from history"
    )

    func run() throws {
        let config = Config.load()
        let storage = try Storage(config: config)
        let entries = storage.list(limit: 1)
        guard let entry = entries.first else {
            print("No clipboard entries.")
            throw ExitCode.failure
        }
        guard entry.type == .text || entry.type == .filePath else {
            FileHandle.standardError.write("Entry \(entry.id) is \(entry.type.rawValue), not text.\n".data(using: .utf8)!)
            throw ExitCode.failure
        }
        guard let data = storage.readClipData(entry: entry),
              let str = String(data: data, encoding: .utf8) else {
            FileHandle.standardError.write("Clip file missing.\n".data(using: .utf8)!)
            throw ExitCode.failure
        }
        print(str, terminator: "")
        try storage.delete(id: entry.id)
    }
}

struct Frequent: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "frequent",
        abstract: "Show most frequently copied entries"
    )

    @Option(name: .shortAndLong, help: "Number of entries to show")
    var count: Int = 10

    func run() throws {
        let config = Config.load()
        let storage = try Storage(config: config)
        let entries = storage.mostFrequent(limit: count)

        if entries.isEmpty {
            print("No frequently copied entries yet.")
            return
        }

        let dim = "\u{001B}[2m"
        let reset = "\u{001B}[0m"
        let bold = "\u{001B}[1m"
        let cyan = "\u{001B}[36m"
        let idWidth = entries.map { String($0.entry.id).count }.max() ?? 1

        for fe in entries {
            let e = fe.entry
            let idStr = String(e.id).padding(toLength: idWidth, withPad: " ", startingAt: 0)
            var preview = String(e.preview.prefix(60))
            if preview.hasSuffix("\\n") { preview = String(preview.dropLast(2)) }
            print("\(dim)\(idStr)\(reset)  \(cyan)×\(fe.copyCount)\(reset)  \(bold)\(preview)\(reset)")
        }

        print("\n\(dim)Top \(entries.count) by copy frequency.\(reset)")
    }
}

struct Pin: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pin an entry (prevents auto-deletion)")

    @Argument(help: "Entry ID")
    var id: Int64

    func run() throws {
        let config = Config.load()
        let storage = try Storage(config: config)
        guard storage.get(id: id) != nil else {
            print("Entry \(id) not found")
            throw ExitCode.failure
        }
        try storage.pin(id: id)
        print("Pinned entry \(id)")
    }
}

struct Unpin: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Unpin an entry")

    @Argument(help: "Entry ID")
    var id: Int64

    func run() throws {
        let config = Config.load()
        let storage = try Storage(config: config)
        guard storage.get(id: id) != nil else {
            print("Entry \(id) not found")
            throw ExitCode.failure
        }
        try storage.unpin(id: id)
        print("Unpinned entry \(id)")
    }
}

struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete a specific entry")

    @Argument(help: "Entry ID")
    var id: Int64

    @Flag(name: .shortAndLong, help: "Skip confirmation")
    var yes = false

    func run() throws {
        let config = Config.load()
        let storage = try Storage(config: config)
        guard let entry = storage.get(id: id) else {
            print("Entry \(id) not found")
            throw ExitCode.failure
        }
        if !yes {
            let preview = String(entry.preview.prefix(60))
            print("Delete entry \(id) (\(preview))? [y/N] ", terminator: "")
            guard let answer = readLine(), answer.lowercased() == "y" else {
                print("Cancelled.")
                return
            }
        }
        try storage.delete(id: id)
        print("Deleted entry \(id)")
    }
}

struct DeleteMatching: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-matching",
        abstract: "Delete all entries matching a search query",
        shouldDisplay: false
    )

    @Argument(help: "Search term")
    var query: String

    func run() throws {
        let config = Config.load()
        let storage = try Storage(config: config)
        let entries = storage.search(query: query, limit: 10000)
        var count = 0
        for entry in entries {
            try storage.delete(id: entry.id)
            count += 1
        }
        print("Deleted \(count) entries matching \"\(query)\"")
    }
}

struct Scrub: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Find and flag/delete entries matching sensitive patterns (keys, tokens, etc.)")

    @Flag(name: .long, help: "Preview without acting")
    var dryRun = false

    @Flag(name: .long, help: "Delete sensitive entries instead of just flagging them")
    var delete = false

    func run() throws {
        let config = Config.load()
        let storage = try Storage(config: config)
        let allEntries = storage.list(limit: 100000)

        var unflagged: [ClipEntry] = []
        for entry in allEntries {
            if !entry.sensitive && config.isSensitive(entry.preview) {
                unflagged.append(entry)
            }
        }

        if unflagged.isEmpty {
            print("No unflagged sensitive entries found.")
            return
        }

        printEntries(unflagged, showBranch: true)

        if dryRun {
            let verb = delete ? "deleted" : "flagged as sensitive"
            print("\n\u{001B}[33m\(unflagged.count) entry/entries would be \(verb). Run without --dry-run to apply.\u{001B}[0m")
        } else if delete {
            for entry in unflagged {
                try storage.delete(id: entry.id)
            }
            print("\n\u{001B}[31mDeleted \(unflagged.count) sensitive entry/entries.\u{001B}[0m")
        } else {
            for entry in unflagged {
                try storage.markSensitive(id: entry.id)
            }
            print("\nFlagged \(unflagged.count) entry/entries as sensitive (redacted in list, still accessible via get).")
        }
    }
}

struct Clear: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete all saved entries")

    @Flag(name: .shortAndLong, help: "Skip confirmation")
    var yes = false

    func run() throws {
        let config = Config.load()
        let storage = try Storage(config: config)
        let count = storage.entryCount()

        if count == 0 {
            print("No entries to clear.")
            return
        }

        if !yes {
            print("Delete \(count) clipboard entries? [y/N] ", terminator: "")
            guard let answer = readLine(), answer.lowercased() == "y" else {
                print("Cancelled.")
                return
            }
        }

        try storage.clearAll()
        print("Cleared \(count) entries.")
    }
}

struct BranchCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "branch",
        abstract: "Show or switch the active branch"
    )

    @Argument(help: "Branch name to switch to (omit to show current)")
    var name: String?

    func run() {
        if let name = name {
            let branch = name == "-" ? "main" : name
            BranchState.set(branch)
            print("Switched to branch \"\(branch)\"")
        } else {
            let current = BranchState.current()
            print(current)
        }
    }
}

struct BranchesCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "branches",
        abstract: "List all branches"
    )

    func run() throws {
        let config = Config.load()
        let storage = try Storage(config: config)
        let branches = storage.listBranches()
        let current = BranchState.current()

        let dim = "\u{001B}[2m"
        let reset = "\u{001B}[0m"
        let bold = "\u{001B}[1m"
        let green = "\u{001B}[32m"

        if branches.isEmpty {
            print("No branches yet.")
            return
        }

        for b in branches {
            let marker = b.name == current ? "\(green)* " : "  "
            let nameStr = b.name == current ? "\(bold)\(b.name)\(reset)" : b.name
            let countStr = "\(dim)\(b.count) clips\(reset)"
            print("\(marker)\(nameStr)  \(countStr)")
        }
    }
}

struct MoveCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Move an entry to a different branch"
    )

    @Argument(help: "Entry ID")
    var id: Int64

    @Argument(help: "Target branch")
    var branch: String

    func run() throws {
        let config = Config.load()
        let storage = try Storage(config: config)
        guard storage.get(id: id) != nil else {
            print("Entry \(id) not found")
            throw ExitCode.failure
        }
        try storage.moveToBranch(id: id, branch: branch)
        print("Moved entry \(id) to branch \"\(branch)\"")
    }
}

struct ConfigCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show current configuration"
    )

    func run() {
        let config = Config.load()
        print("Storage directory:  \(config.storageDir)")
        print("Poll interval:     \(config.pollInterval)s")
        print("Max entries:       \(config.maxEntries)")
        print("Max entry size:    \(config.maxEntrySize / 1024 / 1024)MB")
        print("Excluded apps:     \(config.excludedApps.isEmpty ? "(none)" : config.excludedApps.joined(separator: ", "))")
        print("Compress after:    \(config.compressAfterDays) days")
        print("TTL:               \(config.ttlDays) days")
        print("Active branch:     \(BranchState.current())")
        if !config.branchRules.isEmpty {
            let rules = config.branchRules.map { "\($0.app) -> \($0.branch)" }.joined(separator: ", ")
            print("Branch rules:      \(rules)")
        }
        print("\nConfig file: \(Config.configPath)")
    }
}

// Hidden subcommand used when launching the daemon process
struct DaemonCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_daemon",
        shouldDisplay: false
    )

    func run() throws {
        try Daemon.runLoop()
    }
}
