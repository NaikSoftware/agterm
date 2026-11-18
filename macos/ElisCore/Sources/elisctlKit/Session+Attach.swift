import ArgumentParser
import Foundation
import ElisCore

extension Session {
    struct Attach: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Attach this terminal to a Live pane as a passive viewer.",
            discussion: """
            Replaces this process with the viewer command, on your stdio. With --json it prints the response and does not attach. \
            The viewer ends when its process is killed or the pane's session ends; keys typed into it are dropped, the detach key too.
            """)
        @Option(name: .long, help: "Which pane: primary/left/top or split/right/bottom. Defaults to primary.") var pane: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        enum Action: Equatable {
            case exec([String])
            case print(String)
            /// A refused `--json` reply: the line goes to stdout like every command's, then the exit is nonzero.
            case printThenFail(String)
            case fail(String)
        }

        func validate() throws {
            try validateGridPane(pane)
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionAttach, target: target.target, args: options.withWindow(ControlArgs(pane: pane)))
        }

        static func decide(_ reply: SocketReply, json: Bool, callerPaneID: String?) -> Action {
            if json { return reply.response.ok ? .print(reply.line) : .printThenFail(reply.line) }
            guard reply.response.ok else { return .fail(SocketClient.formatResponse(reply.response)) }
            guard let attach = reply.response.result?.attach, !attach.argv.isEmpty else {
                return .fail("error: the response carries no attach command")
            }
            // the pane would print its own output back into itself, and the viewer drops every key
            if attach.paneID == callerPaneID { return .fail("error: cannot attach a pane to itself") }
            return .exec(attach.argv)
        }

        func run() throws {
            let reply = try SocketClient(path: options.socketPath()).send(makeRequest())
            switch Self.decide(reply, json: options.json, callerPaneID: ProcessInfo.processInfo.environment["ELIS_PANE_ID"]) {
            case .print(let line): print(line)
            case .printThenFail(let line):
                print(line)
                throw ExitCode.failure
            case .fail(let message):
                FileHandle.standardError.write(Data((message + "\n").utf8))
                throw ExitCode.failure
            case .exec(let argv):
                var cArgs = argv.map { strdup($0) } + [nil]
                defer { cArgs.forEach { free($0) } }
                execvp(argv[0], &cArgs)
                FileHandle.standardError.write(Data(("error: \(argv[0]): " + String(cString: strerror(errno)) + "\n").utf8))
                throw ExitCode.failure
            }
        }
    }
}
