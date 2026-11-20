import Foundation

/// MarkdownAssets is the renderers markdown and text pages run and the stylesheets they wear, read once from
/// a `markdown` folder. No folder reads as empty, and so does a missing file, which leaves the page blank
/// rather than failing.
public struct MarkdownAssets: Sendable {
    /// script is markdown-it, highlight.js and the page's own render.js, in the order they depend on each other.
    public let script: String
    public let style: String
    /// textScript is highlight.js and text.js, with no markdown parser; textStyle is the markdown stylesheet
    /// with text.css over it, for the theme colors and highlight rules both pages share.
    public let textScript: String
    public let textStyle: String

    public init(directory: URL?) {
        guard let directory else {
            (script, style, textScript, textStyle) = ("", "", "", "")
            return
        }
        let read = { (name: String) -> String in
            (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        script = ["markdown-it-14.1.0.min.js", "highlight-11.11.1.min.js", "render.js"].map(read).joined(separator: ";\n")
        style = read("page.css")
        textScript = ["highlight-11.11.1.min.js", "text.js"].map(read).joined(separator: ";\n")
        textStyle = style + "\n" + read("text.css")
    }
}
