import WebKit
import ElisCore

/// HtmlBridgeDispatch runs one control request for a page, through the same entry point as the control socket.
typealias HtmlBridgeDispatch = @MainActor (ControlRequest) async -> ControlResponse

/// HtmlOverlayBridge lets a file page run elis commands. elis's own script turns `data-elis` tags into
/// requests; it lives in a world of its own, so it runs with the page's JavaScript off and the page cannot
/// replace it, while the DOM it listens on is shared with the page. A `--js` page also gets `elis.request`
/// in its own world, over a second registration of the same handler.
@MainActor
enum HtmlOverlayBridge {
    static let world = WKContentWorld.world(name: "elis-bridge")
    static let handlerName = "elis"

    static let adapterScript = HtmlBridgeAdapter.script(handler: "window.webkit.messageHandlers.\(handlerName)")
    static let helperScript = HtmlBridgeAdapter.helperScript(handler: "window.webkit.messageHandlers.\(handlerName)")

    /// reply shapes a response for the page: the result as a JSON object, or the error for a refused request.
    static func reply(_ response: ControlResponse) -> (Any?, String?) {
        guard response.ok else { return (nil, response.error ?? "request failed") }
        guard let result = response.result, let data = try? JSONEncoder().encode(result),
              let object = try? JSONSerialization.jsonObject(with: data) else { return ([String: Any](), nil) }
        return (object, nil)
    }

    /// reply shapes a reply the origin sent as JSON text, read untyped so a result field this Mac's build does
    /// not know still reaches the page.
    static func reply(raw: String) -> (Any?, String?) {
        guard let envelope = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            return (nil, "invalid reply")
        }
        guard envelope["ok"] as? Bool == true else { return (nil, envelope["error"] as? String ?? "request failed") }
        return (envelope["result"] ?? [String: Any](), nil)
    }
}

/// HtmlOverlayBridgeHandler receives a page's requests. WebKit keeps it strongly for the page's lifetime, so it
/// holds the page weakly and answers `page closed` once the page is gone.
@MainActor
final class HtmlOverlayBridgeHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var page: HtmlOverlayPage?

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let page else { return replyHandler(nil, "page closed") }
        page.handleBridgeRequest(message.body, mainFrame: message.frameInfo.isMainFrame, reply: replyHandler)
    }
}
