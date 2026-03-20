import AppKit
import CommonCrypto
import Foundation

struct ClipContent {
    let representations: [ClipRepresentation]
    let preview: String
    let primaryType: ClipType
    let totalSize: Int

    var combinedHash: String {
        var allData = Data()
        for rep in representations {
            allData.append(rep.data)
        }
        return ClipboardMonitor.sha256(allData)
    }
}

struct ClipRepresentation {
    let uti: String
    let data: Data
    let filename: String
}

final class ClipboardMonitor {
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int

    init() {
        self.lastChangeCount = pasteboard.changeCount
    }

    func hasChanged() -> Bool {
        let current = pasteboard.changeCount
        if current != lastChangeCount {
            lastChangeCount = current
            return true
        }
        return false
    }

    /// Capture ALL representations from the pasteboard
    func currentContent() -> ClipContent? {
        guard let types = pasteboard.types, !types.isEmpty else { return nil }

        var representations: [ClipRepresentation] = []
        var seenUTIs = Set<String>()

        for type in types {
            let uti = type.rawValue
            guard !seenUTIs.contains(uti) else { continue }
            guard let data = pasteboard.data(forType: type), !data.isEmpty else { continue }
            seenUTIs.insert(uti)

            let filename = Self.filename(for: uti)
            representations.append(ClipRepresentation(uti: uti, data: data, filename: filename))
        }

        guard !representations.isEmpty else { return nil }

        let (primaryType, preview) = Self.classifyAndPreview(types: types, pasteboard: pasteboard, representations: representations)
        let totalSize = representations.reduce(0) { $0 + $1.data.count }

        return ClipContent(
            representations: representations,
            preview: preview,
            primaryType: primaryType,
            totalSize: totalSize
        )
    }

    func frontmostApp() -> String? {
        return NSWorkspace.shared.frontmostApplication?.localizedName
    }

    // MARK: - Helpers

    private static func classifyAndPreview(types: [NSPasteboard.PasteboardType], pasteboard: NSPasteboard, representations: [ClipRepresentation]) -> (ClipType, String) {
        // File URLs
        if types.contains(.fileURL),
           let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            let preview = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
            return (.filePath, preview)
        }

        // Pure image (no text companion)
        let hasImage = types.contains(.png) || types.contains(.tiff)
        let hasText = types.contains(.string)
        if hasImage && !hasText {
            let imgRep = representations.first { $0.uti == NSPasteboard.PasteboardType.png.rawValue || $0.uti == NSPasteboard.PasteboardType.tiff.rawValue }
            let sizeKB = (imgRep?.data.count ?? 0) / 1024
            return (.image, "[image \(sizeKB)KB]")
        }

        // Text (possibly with rich/HTML/image representations — all stored regardless)
        if let str = pasteboard.string(forType: .string), !str.isEmpty {
            let preview = String(str.prefix(5000)).replacingOccurrences(of: "\n", with: "\\n")
            return (.text, preview)
        }

        // Fallback
        let utis = representations.map(\.uti).prefix(3).joined(separator: ", ")
        let totalKB = representations.reduce(0) { $0 + $1.data.count } / 1024
        return (.text, "[\(utis)] \(totalKB)KB")
    }

    static func filename(for uti: String) -> String {
        switch uti {
        case "public.utf8-plain-text", "public.plain-text": return "text.txt"
        case "public.html": return "html.html"
        case "public.rtf": return "rtf.rtf"
        case "public.png": return "image.png"
        case "public.tiff": return "image.tiff"
        case "public.file-url": return "fileurl.txt"
        case "com.apple.webarchive": return "webarchive.dat"
        case "org.chromium.source-url": return "source-url.txt"
        default:
            let safe = uti.replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
            return "\(safe).dat"
        }
    }

    static func sha256(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
