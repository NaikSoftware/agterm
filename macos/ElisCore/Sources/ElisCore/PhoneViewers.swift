import Foundation

/// The phone's open panes per `paneID` (the `tree` `surfaces[].paneID` token), counted from the relay's
/// `phone attached` / `phone detached` lines. `PhoneRelay` owns the one instance.
public struct PhoneViewers: Equatable, Sendable {
    private var counts: [String: Int] = [:]

    public init() {}

    public mutating func attach(paneID: String) { counts[paneID, default: 0] += 1 }

    /// False when no viewer of `paneID` was counted.
    public mutating func detach(paneID: String) -> Bool {
        guard let count = counts[paneID] else { return false }
        counts[paneID] = count > 1 ? count - 1 : nil
        return true
    }

    /// Clears every count and returns one `paneID` per viewer that was counted.
    public mutating func reset() -> [String] {
        defer { counts = [:] }
        return counts.flatMap { Array(repeating: $0.key, count: $0.value) }
    }

    public func count(paneID: String) -> Int { counts[paneID] ?? 0 }
}
