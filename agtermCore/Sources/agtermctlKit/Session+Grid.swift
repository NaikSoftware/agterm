import ArgumentParser
import agtermCore

extension Session {
    struct Grid: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Give a pane's program a grid apart from the window, or hand it back with --reset.",
            discussion: "A phone uses this to fit the program to its screen. Read the forced grid from `tree`'s `paneGrids`.")
        @Argument(help: "The grid as <columns>x<rows>, such as 80x24 (columns 20...1000, rows 5...1000).") var size: String?
        @Flag(name: .long, help: "Return the pane to the grid its view gives it.") var reset = false
        @Option(name: .long, help: "Which pane: primary/left/top or split/right/bottom. Defaults to primary.") var pane: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws {
            guard (size == nil) == reset else { throw ValidationError("provide <columns>x<rows> or --reset") }
            if size != nil, parsedSize == nil { throw ValidationError("size must be <columns>x<rows>, such as 80x24") }
            try validatePaneArgument(pane)
        }

        private var parsedSize: (columns: Int, rows: Int)? {
            let parts = size?.split(separator: "x", omittingEmptySubsequences: false) ?? []
            guard parts.count == 2, let columns = Int(parts[0]), let rows = Int(parts[1]) else { return nil }
            return (columns, rows)
        }

        func makeRequest() throws -> ControlRequest {
            var args = ControlArgs(pane: pane)
            if reset {
                args.reset = true
            } else {
                args.columns = parsedSize?.columns
                args.rows = parsedSize?.rows
            }
            return ControlRequest(cmd: .sessionGrid, target: target.target, args: options.withWindow(args))
        }
    }

    struct Scroll: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Wheel a pane like a mouse over it, so a full-screen program scrolls its own view.")
        // an array of unrecognized words, because a plain Int argument reads `-3` as an unknown option
        @Argument(parsing: .allUnrecognized,
                  help: "Wheel lines, -1000...1000 and not 0; negative scrolls up toward older output.") var lines: [String] = []
        @Option(name: .long, help: "Which pane: primary/left/top or split/right/bottom. Defaults to primary.") var pane: String?
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws {
            guard lines.count == 1, Int(lines[0]) != nil else { throw ValidationError("provide one whole number of lines") }
            try validatePaneArgument(pane)
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionScroll, target: target.target,
                           args: options.withWindow(ControlArgs(pane: pane, lines: lines.first.flatMap { Int($0) })))
        }
    }
}
