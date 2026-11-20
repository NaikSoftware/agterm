import Foundation
import ElisCore

/// MarkdownProbe reads a markdown file named by untrusted output, with the local pictures it references
/// embedded until the page's byte or pixel budget runs out; a picture left out renders as its alt text.
struct MarkdownProbe: Sendable {
    let markdown: String
    let images: MarkdownPage.Embedded

    static func load(path: String) -> Result<MarkdownProbe, MarkdownFile.Failure> {
        let read = BoundedFile.read(path: path, maxBytes: MarkdownPage.maxBytes).mapError { MarkdownFile.Failure($0, path: path) }
        return read.flatMap { data in
            guard let markdown = String(data: data, encoding: .utf8) else { return .failure(.notText(path)) }
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
            return .success(MarkdownProbe(markdown: markdown, images: embed(MarkdownPage.imageReferences(in: markdown, folder: folder))))
        }
    }

    private static func embed(_ references: [MarkdownPage.Image]) -> MarkdownPage.Embedded {
        var embedding = MarkdownEmbedding()
        for image in references {
            guard let room = embedding.room(for: image) else { continue }
            embedding.add(image, (try? ImageProbe.load(path: image.path, maxBytes: room).get()).map(picture))
        }
        return embedding.embedded
    }

    /// picture is a probed read as `MarkdownEmbedding` takes it.
    static func picture(_ read: (ImageProbe, Data)) -> (mimeType: String, data: Data, pixels: Int?) {
        (read.0.mimeType, read.1, read.0.pixelWidth * read.0.pixelHeight)
    }
}
