import Foundation
import SaveClipLib

// If the first arg isn't a subcommand but is an existing file, treat as `saveclip add <files>`
let subcommands = Set(SaveClip.configuration.subcommands.map { $0._commandName })

var args = Array(CommandLine.arguments.dropFirst())

if let first = args.first, !first.hasPrefix("-"), !subcommands.contains(first) {
    let fm = FileManager.default
    let path = first.hasPrefix("/") ? first : fm.currentDirectoryPath + "/" + first
    if fm.fileExists(atPath: path) {
        args.insert("add", at: 0)
    } else if Int64(first) != nil {
        args.insert("get", at: 0)
    }
}

SaveClip.main(args)
