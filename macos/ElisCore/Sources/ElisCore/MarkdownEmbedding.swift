import Foundation

/// MarkdownEmbedding collects the pictures one markdown page embeds under its file, byte and pixel budgets, whichever
/// Mac the bytes were read on: each file once, and every reference naming it pointed at that one copy.
public struct MarkdownEmbedding: Sendable {
    public private(set) var embedded = MarkdownPage.Embedded()
    private var read: [String: Int?] = [:]
    private var bytes = 0
    private var pixels = 0

    public init() {}

    /// room is how many bytes reading `image` may take, nil when it needs no read: a file already read, whose
    /// reference is recorded here, or a spent budget.
    public mutating func room(for image: MarkdownPage.Image) -> Int? {
        if let known = read[image.path] {
            if let known { embedded.references[image.reference] = known }
            return nil
        }
        guard read.count < MarkdownPage.maxImages, bytes < MarkdownPage.maxImageBytes,
              pixels < MarkdownPage.maxImagePixels else { return nil }
        return MarkdownPage.maxImageBytes - bytes
    }

    /// add records what reading `image` gave: a picture still inside the pixel budget is embedded, and anything else,
    /// a failed read included, leaves the reference to its alt text. Nil `pixels` spends no pixel budget.
    public mutating func add(_ image: MarkdownPage.Image, _ picture: (mimeType: String, data: Data, pixels: Int?)?) {
        guard let picture, pixels + (picture.pixels ?? 0) <= MarkdownPage.maxImagePixels else {
            read[image.path] = .some(nil)
            return
        }
        bytes += picture.data.count
        pixels += picture.pixels ?? 0
        embedded.uris.append("data:\(picture.mimeType);base64,\(picture.data.base64EncodedString())")
        read[image.path] = embedded.uris.count - 1
        embedded.references[image.reference] = embedded.uris.count - 1
    }
}
