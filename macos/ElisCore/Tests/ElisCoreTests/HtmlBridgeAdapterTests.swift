import Foundation
import Testing
@testable import ElisCore

struct HtmlBridgeAdapterTests {
    @Test func theAdapterPostsThroughTheHandlerItIsGiven() {
        let script = HtmlBridgeAdapter.script(handler: "window.__elis")

        #expect(script.contains("const handler = window.__elis;"))
        #expect(!script.contains("webkit"))
    }

    @Test func theHelperPostsThroughTheHandlerItIsGiven() {
        let script = HtmlBridgeAdapter.helperScript(handler: "window.__elis")

        #expect(script.contains("const handler = window.__elis;"))
        #expect(!script.contains("webkit"))
    }

    @Test func noFolderReadsEmpty() {
        let assets = MarkdownAssets(directory: nil)

        #expect(assets.script == "")
        #expect(assets.style == "")
        #expect(assets.textScript == "")
        #expect(assets.textStyle == "")
    }

    @Test func aFolderWithoutTheFilesReadsEmptyParts() {
        let assets = MarkdownAssets(directory: URL(fileURLWithPath: "/nonexistent-elis-markdown"))

        #expect(assets.script == ";\n;\n")
        #expect(assets.style == "")
        #expect(assets.textScript == ";\n")
        #expect(assets.textStyle == "\n")
    }
}
