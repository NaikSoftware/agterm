import Foundation

/// Drops zmx role reports (`ESC ] 2 ; zmx-role;…` ended by BEL or `ESC \`) from a pane's VT stream, so the
/// phone never shows one as a title. An unfinished report waits for the next call, up to `limit` bytes.
public struct PhoneLinkTitleFilter: Sendable {
    public static let limit = 512
    private static let start = Data([0x1B, 0x5D, 0x32, 0x3B] + Array(ZmxLeadNotice.prefix.utf8))
    private var pending = Data()

    public init() {}

    public mutating func filter(_ bytes: Data) -> Data {
        let data = pending + bytes
        pending = Data()
        var out = Data(capacity: data.count)
        var index = data.startIndex
        while index < data.endIndex {
            let escape = data[index...].firstIndex(of: 0x1B) ?? data.endIndex
            out.append(data[index..<escape])
            index = escape
            guard index < data.endIndex else { break }
            let rest = data[index...]
            if rest.starts(with: Self.start) {
                if let end = Self.end(of: rest) {
                    index = end
                    continue
                }
                // shortcut: a report longer than `limit` passes through as text; real ones are under 100 bytes.
                if rest.count <= Self.limit {
                    pending = Data(rest)
                    break
                }
            } else if Self.start.starts(with: rest) {
                pending = Data(rest)
                break
            }
            out.append(0x1B)
            index += 1
        }
        return out
    }

    /// The index after the BEL or `ESC \` that ends the report at the start of `report`, nil when none came yet.
    private static func end(of report: Data) -> Data.Index? {
        var index = report.startIndex + start.count
        while index < report.endIndex {
            if report[index] == 0x07 { return index + 1 }
            if report[index] == 0x1B, index + 1 < report.endIndex, report[index + 1] == 0x5C { return index + 2 }
            index += 1
        }
        return nil
    }
}
