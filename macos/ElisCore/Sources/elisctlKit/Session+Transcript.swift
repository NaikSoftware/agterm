import ArgumentParser
import ElisCore

extension Session {
    struct Transcript: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print a page of the Claude conversation running in a session's pane.",
            discussion: """
            session transcript --target ID [--after N | --before N] [--transcript CLAUDE_ID]

            Without --after or --before prints the newest items. Pass the printed `next` as --after to read \
            what was appended since, or a page's start as --before to read older items. --json prints the \
            full page, including pending prompts, meta and commands.
            """
        )
        @Option(name: .long, help: "Which pane's Claude: primary/left/top or split/right/bottom. Defaults to the session's agent pane.") var pane: String?
        @Option(name: .customLong("pane-id"), help: "Stable pane token ($ELIS_PANE_ID); overrides --pane when it resolves.") var paneID: String?
        @Option(name: .long, help: "Items appended at or after this byte offset (a previous page's next).") var after: Int?
        @Option(name: .long, help: "Older items before this byte offset (a previous page's start).") var before: Int?
        @Option(name: .long, help: "The Claude session id the caller holds; a different one answers a reset tail page.") var transcript: String?
        @Option(name: .long, help: "Page budget in bytes, capped at 49152.") var maxBytes: Int?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws {
            if after != nil, before != nil {
                throw ValidationError("use either --after or --before, not both")
            }
            if (after ?? 0) < 0 || (before ?? 0) < 0 {
                throw ValidationError("--after and --before must be 0 or greater")
            }
            if let maxBytes, maxBytes <= 0 {
                throw ValidationError("--max-bytes must be greater than 0")
            }
            try validatePaneArgument(pane)
        }

        func makeRequest() throws -> ControlRequest {
            var args = ControlArgs(pane: pane, paneID: paneID, after: after.map(String.init), before: before.map(String.init))
            args.transcript = transcript
            args.maxBytes = maxBytes
            return ControlRequest(cmd: .sessionTranscript, target: target.target, args: options.withWindow(args))
        }
    }
}

extension SocketClient {
    static func formatTranscript(_ result: ControlResult, items: [ControlTranscriptItem]) -> String {
        var lines: [String] = []
        if let title = result.meta?.title { lines.append("title: \(title)") }
        if let model = result.meta?.model { lines.append("model: \(model)") }
        if let mode = result.meta?.permissionMode { lines.append("permissionMode: \(mode)") }
        for agent in result.meta?.agents ?? [] {
            lines.append("agent: " + [agent.state, agent.name ?? agent.agentType, agent.description].compactMap { $0 }.joined(separator: " "))
        }
        for item in items {
            let detail = item.kind == "tool" ? [item.name, item.arg, item.mark].compactMap { $0 }.joined(separator: " ") : item.text ?? ""
            lines.append(detail.isEmpty ? item.kind : "\(item.kind)  \(detail)")
        }
        if let next = result.next { lines.append("next \(next)") }
        return lines.joined(separator: "\n")
    }
}
