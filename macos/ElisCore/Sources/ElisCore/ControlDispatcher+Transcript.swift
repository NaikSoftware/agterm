import Dispatch
import Foundation

/// `session.transcript`'s arguments, validated the same way on every host.
public struct ClaudeTranscriptArguments: Sendable, Equatable {
    public var pane: StatusPane?
    public var paneID: String?
    public var after: Int?
    public var before: Int?
    public var held: String?
    public var maxBytes: Int
}

extension ControlResponse: Error {}

extension ControlDispatcher {
    public static func transcriptArguments(_ args: ControlArgs?) -> Result<ClaudeTranscriptArguments, ControlResponse> {
        func refuse(_ error: String) -> Result<ClaudeTranscriptArguments, ControlResponse> {
            .failure(ControlResponse(ok: false, error: error))
        }
        func offset(_ raw: String?) -> Int?? {
            guard let raw else { return .some(nil) }
            guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(raw) else { return nil }
            return .some(value)
        }
        if args?.after != nil, args?.before != nil { return refuse("use either --after or --before, not both") }
        guard let after = offset(args?.after) else { return refuse("after must be a byte offset") }
        guard let before = offset(args?.before) else { return refuse("before must be a byte offset") }
        if let maxBytes = args?.maxBytes, maxBytes <= 0 { return refuse("max-bytes must be greater than 0") }
        let pane: StatusPane?
        switch parseSurfacePane(args?.pane) {
        case .rejected(let rejection): return .failure(rejection)
        case .pane(let parsed): pane = parsed
        }
        if pane == .scratch { return refuse("session.transcript reads --pane left or right") }
        return .success(ClaudeTranscriptArguments(pane: pane, paneID: args?.paneID, after: after, before: before, held: args?.transcript,
                                                  maxBytes: min(args?.maxBytes ?? ClaudeTranscript.pageBudget, ClaudeTranscript.pageBudget)))
    }

    func dispatchSessionTranscript(_ request: ControlRequest) async -> ControlResponse {
        let arguments: ClaudeTranscriptArguments
        switch Self.transcriptArguments(request.args) {
        case .failure(let refusal): return refusal
        case .success(let parsed): arguments = parsed
        }
        switch actions.transcriptSource(request.target, window: request.args?.window, pane: arguments.pane, paneID: arguments.paneID) {
        case .refused(let refusal): return refusal
        case .source(let source): return await Self.readTranscript(source, arguments)
        }
    }

    // a dispatch queue, never a Task: a first scan of a large file would park a cooperative-pool thread
    nonisolated private static func readTranscript(_ source: ControlTranscriptSource, _ arguments: ClaudeTranscriptArguments) async -> ControlResponse {
        let request = ClaudeTranscriptRequest(sessionID: source.claudeSessionID, after: arguments.after, before: arguments.before,
                                              held: arguments.held, maxBytes: arguments.maxBytes)
        let reader = ClaudeTranscript.instance(directory: source.claudeDirectory)
        let read = await withCheckedContinuation { (continuation: CheckedContinuation<Result<ClaudeTranscriptPage, ClaudeTranscriptError>, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: reader.page(request)) }
        }
        switch read {
        case .failure(let error): return ControlResponse(ok: false, error: error.description)
        case .success(let page):
            var result = ControlResult()
            result.transcript = page.transcript
            result.size = page.size
            result.start = page.start
            result.next = page.next
            result.reset = page.reset ? true : nil
            result.items = page.items
            result.pending = page.pending.isEmpty ? nil : page.pending
            result.meta = page.meta
            result.commands = page.commands
            result.skipped = page.skipped == 0 ? nil : page.skipped
            return ControlResponse(ok: true, result: result)
        }
    }
}
