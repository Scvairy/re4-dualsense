import Foundation

struct TriggerCatalog {
    struct Entry {
        let path: String
        let url: URL
        let gain: Float
        let padMask: UInt32

        func allows(pad: Int32) -> Bool {
            pad == -1 ? padMask != 0 : padMask & (1 << UInt32(pad)) != 0
        }
    }

    let entries: [UInt32: Entry]

    static func directory(for executable: URL) -> URL {
        let parent = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        var directory = parent
        while directory.path != "/" {
            if directory.lastPathComponent == ".build" {
                return directory.deletingLastPathComponent()
            }
            directory.deleteLastPathComponent()
        }
        return parent
    }

    static func load(from directory: URL) throws -> TriggerCatalog {
        let text = try String(contentsOf: directory.appendingPathComponent("triggers.tsv"), encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.first == "hash\twav\tvolume_db\tpadmask\tduration_hd_ms\tduration_ms" else {
            throw HelperError("invalid trigger catalog header")
        }

        var entries: [UInt32: Entry] = [:]
        for (index, row) in lines.dropFirst().enumerated() {
            let columns = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 6, let hash = parseHex(columns[0]),
                  let decibels = Float(columns[2]), decibels.isFinite,
                  let mask = parseHex(columns[3]) else {
                throw HelperError("invalid trigger catalog row \(index + 2)")
            }
            let path = String(columns[1])
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            let gain = pow(10, decibels / 20)
            guard parts.first == "tracks", parts.count > 1,
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  path.hasSuffix(".wav"), !path.contains("\0"), gain.isFinite else {
                throw HelperError("invalid track in trigger catalog row \(index + 2)")
            }
            if entries[hash] == nil {
                let url = directory.appendingPathComponent(path)
                entries[hash] = Entry(path: path, url: url, gain: gain, padMask: mask)
            }
        }
        return TriggerCatalog(entries: entries)
    }

    private static func parseHex(_ text: Substring) -> UInt32? {
        guard text.hasPrefix("0x") else { return nil }
        return UInt32(text.dropFirst(2), radix: 16)
    }
}
