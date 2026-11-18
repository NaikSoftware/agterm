import Foundation
import Testing
@testable import ElisCore

@MainActor
struct ControlDispatcherGridTests {
    private let gridError = "session.grid takes columns and rows, or reset"
    private let rangeError = "session.grid: columns must be 20...1000 and rows 5...1000"
    private let scrollError = "session.scroll: lines must be -1000...1000 and not 0"

    private func dispatch(_ cmd: Command, _ args: ControlArgs?, target: String? = "s") async
        -> (ControlResponse?, MockControlActions) {
        let actions = MockControlActions()
        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: cmd, target: target, args: args))
        return (response, actions)
    }

    private func gridArgs(columns: Int? = nil, rows: Int? = nil, reset: Bool? = nil, pane: String? = nil) -> ControlArgs {
        var args = ControlArgs(pane: pane)
        args.columns = columns
        args.rows = rows
        args.reset = reset
        return args
    }

    @Test func gridRoutesToTheLeftPaneByDefault() async {
        let (_, actions) = await dispatch(.sessionGrid, gridArgs(columns: 80, rows: 24))
        #expect(actions.calls == [.sessionGrid(target: "s", window: nil, pane: .left, ControlGrid(columns: 80, rows: 24))])
    }

    @Test func gridCanonicalizesAPaneAlias() async {
        let (_, actions) = await dispatch(.sessionGrid, gridArgs(columns: 20, rows: 5, pane: "split"))
        #expect(actions.calls == [.sessionGrid(target: "s", window: nil, pane: .right, ControlGrid(columns: 20, rows: 5))])
    }

    @Test func gridResetPassesNoGrid() async {
        let (_, actions) = await dispatch(.sessionGrid, gridArgs(reset: true, pane: "right"))
        #expect(actions.calls == [.sessionGrid(target: "s", window: nil, pane: .right, nil)])
    }

    @Test func gridKeepsTheActionResponse() async {
        let actions = MockControlActions()
        let answer = ControlResponse(ok: true, result: ControlResult(id: "s", pane: "left", columns: 80, rows: 24))
        actions.nextSessionGridResponse = answer
        let response = await ControlDispatcher(actions: actions)
            .dispatch(ControlRequest(cmd: .sessionGrid, target: "s", args: gridArgs(columns: 80, rows: 24)))
        #expect(response == answer)
    }

    @Test func gridRejectsBothOrNeitherOfAGridAndReset() async {
        for args in [gridArgs(columns: 80, rows: 24, reset: true), gridArgs(columns: 80, reset: true), gridArgs(), nil] {
            let (response, actions) = await dispatch(.sessionGrid, args)
            #expect(response == ControlResponse(ok: false, error: gridError))
            #expect(actions.calls.isEmpty)
        }
    }

    @Test(arguments: [(nil, 24), (80, nil), (19, 24), (1001, 24), (80, 4), (80, 1001)] as [(Int?, Int?)])
    func gridRejectsAnIncompleteOrOutOfRangeGrid(columns: Int?, rows: Int?) async {
        let (response, actions) = await dispatch(.sessionGrid, gridArgs(columns: columns, rows: rows))
        #expect(response == ControlResponse(ok: false, error: rangeError))
        #expect(actions.calls.isEmpty)
    }

    @Test(arguments: ["scratch", "middle"])
    func gridAndScrollRejectAPaneOtherThanLeftOrRight(pane: String) async {
        let (grid, gridActions) = await dispatch(.sessionGrid, gridArgs(columns: 80, rows: 24, pane: pane))
        let (scroll, scrollActions) = await dispatch(.sessionScroll, ControlArgs(pane: pane, lines: 3))
        #expect(grid == ControlResponse(ok: false, error: "invalid pane: \(pane)"))
        #expect(scroll == ControlResponse(ok: false, error: "invalid pane: \(pane)"))
        #expect(gridActions.calls.isEmpty && scrollActions.calls.isEmpty)
    }

    @Test func scrollRoutesSignedLines() async {
        let (_, actions) = await dispatch(.sessionScroll, ControlArgs(pane: "bottom", lines: -1000))
        #expect(actions.calls == [.sessionScroll(target: "s", window: nil, pane: .right, lines: -1000)])
    }

    @Test(arguments: [nil, 0, 1001, -1001, Int.min] as [Int?])
    func scrollRejectsLinesOutOfRange(lines: Int?) async {
        let (response, actions) = await dispatch(.sessionScroll, ControlArgs(lines: lines))
        #expect(response == ControlResponse(ok: false, error: scrollError))
        #expect(actions.calls.isEmpty)
    }

    @Test func gridArgsAndResultUseTheWireKeys() throws {
        let args = String(decoding: try JSONEncoder().encode(gridArgs(columns: 80, rows: 24, reset: true)), as: UTF8.self)
        #expect(args.contains("\"columns\":80") && args.contains("\"rows\":24") && args.contains("\"reset\":true"))
        let result = String(decoding: try JSONEncoder().encode(ControlResult(columns: 80, rows: 24, lines: -3)), as: UTF8.self)
        #expect(result.contains("\"columns\":80") && result.contains("\"rows\":24") && result.contains("\"lines\":-3"))
        #expect(!String(decoding: try JSONEncoder().encode(ControlResult()), as: UTF8.self).contains("columns"))
    }

    @Test func treeReportsOnlyTheForcedPaneGrids() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        _ = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        let forced = ControlPaneGrids(right: ControlGrid(columns: 40, rows: 30))

        let plain = try #require(store.controlTree(paneForeground: { _ in nil }).workspaces.first?.sessions.first)
        let fitted = try #require(store.controlTree(paneForeground: { _ in nil }, paneGrids: { _ in forced })
            .workspaces.first?.sessions.first)

        #expect(plain.paneGrids == nil)
        #expect(!String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("paneGrids"))
        #expect(fitted.paneGrids == forced)
        let sorted = JSONEncoder()
        sorted.outputFormatting = .sortedKeys
        #expect(String(decoding: try sorted.encode(fitted), as: UTF8.self)
            .contains("\"paneGrids\":{\"right\":{\"columns\":40,\"rows\":30}}"))
    }
}
