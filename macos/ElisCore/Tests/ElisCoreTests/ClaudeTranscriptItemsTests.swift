import Foundation
import Testing
@testable import ElisCore

struct ClaudeTranscriptItemsTests {
    private func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    private func items(_ record: String, result: String? = nil, spilled: @escaping (String) -> Data? = { _ in nil }) -> [ControlTranscriptItem] {
        ClaudeTranscriptItems.items(record: json(record), at: 100, result: result.map(json), spilled: spilled)
    }

    private func encoded(_ item: ControlTranscriptItem) -> String {
        String(decoding: try! JSONEncoder().encode(item), as: UTF8.self)
    }

    private func toolUse(_ name: String, input: String, id: String = "t1") -> String {
        #"{"type":"assistant","uuid":"a1","timestamp":"T","message":{"id":"msg_1","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}]}}"#
    }

    private func toolResult(_ content: String, isError: Bool = false, extra: String = "", id: String = "t1") -> String {
        #"{"type":"user","uuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":\#(content),"is_error":\#(isError)}]}\#(extra)}"#
    }

    private func tool(_ name: String, input: String, result: String?, spilled: @escaping (String) -> Data? = { _ in nil }) -> ControlTranscriptItem {
        let list = items(toolUse(name, input: input), result: result, spilled: spilled)
        #expect(list.count == 1)
        return list[0]
    }

    // Captured from Claude Code 2.1.329: Bash "No", Bash "No" with a reason, plan "Tell Claude what to change", AskUserQuestion "Chat about this".
    private static let rejections = [
        #""The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_stri"# +
                #"ng was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.\n\nNote: The "# +
                #"user's next message may contain a correction or preference. Pay close attention — if they explain what went wrong or how"# +
                #" they'd prefer you to work, consider saving that to memory for future sessions.""#,
        #""The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_stri"# +
                #"ng was NOT written to the file). To tell you how to proceed, the user said:\nuse node instead\n\nNote: The user's next m"# +
                #"essage may contain a correction or preference. Pay close attention — if they explain what went wrong or how they'd prefe"# +
                #"r you to work, consider saving that to memory for future sessions.""#,
        #""The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_stri"# +
                #"ng was NOT written to the file). To tell you how to proceed, the user said:\nname it hi.txt\n\nNote: The user's next mes"# +
                #"sage may contain a correction or preference. Pay close attention — if they explain what went wrong or how they'd prefer "# +
                #"you to work, consider saving that to memory for future sessions.""#,
        #""The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_stri"# +
                #"ng was NOT written to the file). To tell you how to proceed, the user said:\nThe user wants to clarify these questions."# +
                #"\n    This means they may have additional information, context or questions for you.\n    Take their response into accoun"# +
                #"t and then reformulate the questions if appropriate.\n    Start by asking them what they would like to clarify.\n\n    Q"# +
                #"uestions asked:\n- \"Favorite color?\"\n  (No answer provided)\n\nNote: The user's next message may contain a correction"# +
                #" or preference. Pay close attention — if they explain what went wrong or how they'd prefer you to work, consider saving "# +
                #"that to memory for future sessions.""#,
    ]

    @Test func userRejectionSetsRejected() {
        for (name, text) in zip(["Bash", "Bash", "ExitPlanMode", "AskUserQuestion"], Self.rejections) {
            let item = tool(name, input: #"{"command":"x"}"#, result: toolResult(text, isError: true))
            #expect(item.rejected == true)
            #expect(item.isError == true)
        }
    }

    @Test func failedApprovedBashIsNotRejected() {
        let item = tool("Bash", input: #"{"command":"exit 3"}"#,
                        result: toolResult(#""Exit code 3""#, isError: true, extra: #","toolUseResult":"Error: Exit code 3""#))
        #expect(item.isError == true)
        #expect(item.exitCode == 3)
        #expect(item.mark == "exit 3")
        #expect(!encoded(item).contains("rejected"))
        let hook = #""PreToolUse:Write hook error: check pending for prompt 4 of this session, no check yet.""#
        let held = tool("Write", input: #"{"file_path":"/a/p.md","content":"x"}"#, result: toolResult(hook, isError: true))
        #expect(held.isError == true)
        #expect(held.rejected == nil)
    }

    @Test func typedUserPromptKeepsSourceAndOrigin() {
        let list = items(#"{"type":"user","uuid":"u1","timestamp":"2026-11-19T23:56:59.253Z","message":{"role":"user","content":"Run it"},"origin":{"kind":"human"},"promptSource":"typed"}"#)
        #expect(list.count == 1)
        #expect(list[0].kind == "user")
        #expect(list[0].text == "Run it")
        #expect(list[0].promptSource == "typed")
        #expect(list[0].origin == "human")
        #expect(list[0].uuid == "u1")
        #expect(list[0].at == 100)
        #expect(list[0].time == "2026-11-19T23:56:59.253Z")
    }

    @Test func metaAndToolResultOnlyUserRecordsYieldNothing() {
        #expect(items(#"{"type":"user","uuid":"u1","isMeta":true,"message":{"role":"user","content":"<command-name>x</command-name>"}}"#).isEmpty)
        #expect(items(toolResult(#""ok""#)).isEmpty)
    }

    @Test func wrapperTagsBecomeCommandOutputBash() {
        let command = items(#"{"type":"user","uuid":"u1","message":{"role":"user","content":"<command-name>/compact</command-name>\n            <comma"# +
                #"nd-message>compact</command-message>\n            <command-args>x</command-args>"}}"#)
        #expect(command.map(\.kind) == ["command"])
        #expect(command.first?.name == "compact")
        #expect(command.first?.args == "x")
        let output = items(#"{"type":"user","uuid":"u1","message":{"role":"user","content":"<local-command-stdout>Cancelled</local-command-stdout>"}}"#)
        #expect(output.map(\.kind) == ["commandOutput"])
        #expect(output.first?.text == "Cancelled")
        let bash = items(#"{"type":"user","uuid":"u1","message":{"role":"user","content":"<bash-input>echo pasted-bang</bash-input>"}}"#)
        #expect(bash.map(\.kind) == ["bash"])
        #expect(bash.first?.text == "echo pasted-bang")
        let bashOut = items(#"{"type":"user","uuid":"u1","message":{"role":"user","content":"<bash-stdout>pasted-bang</bash-stdout><bash-stderr></bash-stderr>"}}"#)
        #expect(bashOut.map(\.kind) == ["commandOutput"])
        #expect(bashOut.first?.text == "pasted-bang")
        #expect(items(#"{"type":"user","uuid":"u1","message":{"role":"user","content":"<system-reminder>hidden</system-reminder>"}}"#).isEmpty)
    }

    @Test func localCommandSystemRecordsUseTheSameTags() {
        let command = items(#"{"type":"system","subtype":"local_command","uuid":"s1","content":"<command-name>/model</command-name>\n            <comm"# +
                #"and-message>model</command-message>\n            <command-args></command-args>","level":"info"}"#)
        #expect(command.map(\.kind) == ["command"])
        #expect(command.first?.name == "model")
        let output = items(#"{"type":"system","subtype":"local_command","uuid":"s2","content":"<local-command-stdout>Kept model as `Haiku 5.5`</local"# +
                #"-command-stdout>","level":"info","commandRun":{"command":"model","args":""}}"#)
        #expect(output.map(\.kind) == ["commandOutput"])
        #expect(output.first?.text == "Kept model as `Haiku 5.5`")
    }

    @Test func interruptMarkerAndAbortedMidStream() {
        let marker = items(#"{"type":"user","uuid":"u1","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#)
        #expect(marker.map(\.kind) == ["interrupted"])
        let plain = items(#"{"type":"user","uuid":"u1","message":{"role":"user","content":"[Request interrupted by user]"},"interruptedMessageId":"msg_1"}"#)
        #expect(plain.map(\.kind) == ["interrupted"])
        let aborted = items(#"{"type":"assistant","uuid":"a1","isAbortedMidStream":true,"message":{"id":"msg_1","content":[{"type":"text","text":"half"}]}}"#)
        #expect(aborted.map(\.kind) == ["text", "interrupted"])
        #expect(aborted.map(\.uuid) == ["a1", "a1#1"])
    }

    @Test func compactSummary() {
        let summary = items(#"{"type":"user","uuid":"u1","isCompactSummary":true,"message":{"role":"user","content":"<artifact-content-authored-by-oth"# +
                #"ers/>\nThis session is being continued.\n<system-reminder>x</system-reminder>"}}"#)
        #expect(summary.map(\.kind) == ["compactSummary"])
        #expect(summary.first?.text?.contains("This session is being continued.") == true)
    }

    @Test func assistantTextCarriesMessageID() {
        let list = items(#"{"type":"assistant","uuid":"a1","message":{"id":"msg_1","content":[{"type":"text","text":"Hello"}]}}"#)
        #expect(list.map(\.kind) == ["text"])
        #expect(list.first?.text == "Hello")
        #expect(list.first?.message == "msg_1")
    }

    @Test func thinkingShowsDurationOnly() {
        let list = items(#"{"type":"assistant","uuid":"a1","thinkingDurationMs":1361,"message":{"id":"msg_1","content":[{"type":"thinking","thinking":"secret plan","signature":"x"}]}}"#)
        #expect(list.map(\.kind) == ["thinking"])
        #expect(list.first?.durationMs == 1361)
        #expect(!encoded(list[0]).contains("\"text\""))
        #expect(!encoded(list[0]).contains("secret"))
    }

    @Test func bashToolMarksExitCode() {
        let item = tool("Bash", input: #"{"command":"make","description":"Build it"}"#,
                        result: toolResult(#""Exit code 2\nmake: *** error""#, isError: true))
        #expect(item.exitCode == 2)
        #expect(item.mark == "exit 2")
        #expect(item.isError == true)
        #expect(item.arg == "Build it")
        #expect(item.output == "Exit code 2\nmake: *** error")
        #expect(item.running == nil)
        let ok = tool("Bash", input: #"{"command":"ls"}"#, result: toolResult(#""(Bash completed with no output)""#))
        #expect(ok.mark == "ok")
        #expect(ok.arg == "ls")
        #expect(ok.isError == nil)
    }

    @Test func editToolCarriesPatchAndCounts() {
        let patch = #"[{"oldStart":1,"oldLines":2,"newStart":1,"newLines":3,"lines":[" a","-b","+c","+d"]}]"#
        let item = tool("Edit", input: #"{"file_path":"/a/b.swift","old_string":"b","new_string":"c\nd"}"#,
                        result: toolResult(#""The file /a/b.swift has been updated successfully.""#,
                                           extra: #","toolUseResult":{"type":"update","filePath":"/a/b.swift","structuredPatch":\#(patch)}"#))
        #expect(item.mark == "+2 \u{2212}1")
        #expect(item.file == "/a/b.swift")
        #expect(item.arg == "b.swift")
        #expect(item.patch == [ControlTranscriptHunk(oldStart: 1, oldLines: 2, newStart: 1, newLines: 3, lines: [" a", "-b", "+c", "+d"])])
        #expect(item.output == nil)
    }

    @Test func writeCreateCountsContentLines() {
        let item = tool("Write", input: #"{"file_path":"/a/n.txt","content":"1\n2\n3\n"}"#,
                        result: toolResult(#""File created successfully at: /a/n.txt""#,
                                           extra: #","toolUseResult":{"type":"create","filePath":"/a/n.txt","content":"1\n2\n3\n","structuredPatch":[]}"#))
        #expect(item.mark == "+3")
    }

    @Test func openToolIsRunning() {
        let item = tool("Bash", input: #"{"command":"sleep 9"}"#, result: nil)
        #expect(item.running == true)
        #expect(item.mark == "running")
        #expect(item.id == "t1")
        #expect(item.name == "Bash")
    }

    @Test func outputClipsAt4KiB() {
        let text = String(repeating: "абв", count: 1800)
        let item = tool("Bash", input: #"{"command":"cat"}"#, result: toolResult(#""\#(text)""#))
        let output = item.output ?? ""
        #expect(output.utf8.count <= 4096)
        #expect(output.utf8.count > 4000)
        #expect(text.hasPrefix(output))
        #expect(item.clipped == true)
    }

    @Test func spilledOutputContributesItsHead() {
        let full = Data(String(repeating: "яz", count: 3500).utf8)
        var asked: [String] = []
        let preview = #""<persisted-output>\nOutput too large (10KB). Full output saved to: /x/tool-results/t1.txt\n\nPreview (first 2KB):\nяz""#
        let item = tool("Bash", input: #"{"command":"cat"}"#, result: toolResult(preview)) { id in
            asked.append(id)
            return full
        }
        #expect(asked == ["t1"])
        let output = item.output ?? ""
        #expect(output.utf8.count <= 4096)
        #expect(output.utf8.count >= 4094)
        #expect(String(repeating: "яz", count: 3500).hasPrefix(output))
        #expect(item.clipped == true)
        let fallback = tool("Bash", input: #"{"command":"cat"}"#, result: toolResult(preview))
        #expect(fallback.output?.hasPrefix("<persisted-output>") == true)
    }

    @Test func readOnlyToolsAreFlagged() {
        #expect(tool("Grep", input: #"{"pattern":"x"}"#, result: toolResult(#""a""#)).readOnly == true)
        let bash = tool("Bash", input: #"{"command":"x"}"#, result: toolResult(#""a""#))
        #expect(bash.readOnly == nil)
        #expect(!encoded(bash).contains("readOnly"))
    }

    @Test func agentToolCarriesTypeAndName() {
        let item = tool("Agent", input: #"{"description":"Find callers","subagent_type":"Explore","name":"scout","prompt":"go"}"#,
                        result: toolResult(#"[{"type":"text","text":"found 3"},{"type":"text","text":"agentId: a1"}]"#))
        #expect(item.agentType == "Explore")
        #expect(item.agentName == "scout")
        #expect(item.arg == "Find callers")
        #expect(item.mark == "done")
        #expect(item.output == "found 3\nagentId: a1")
    }

    @Test func shortArgumentsPerTool() {
        #expect(tool("Read", input: #"{"file_path":"/x/y/z.md"}"#, result: nil).arg == "z.md")
        #expect(tool("WebFetch", input: #"{"url":"https://example.com/a?b","prompt":"p"}"#, result: nil).arg == "example.com")
        #expect(tool("mcp__srv__do", input: #"{"query":"find it","limit":3}"#, result: nil).arg == "3")
        #expect(tool("mcp__srv__do", input: #"{"query":"find it"}"#, result: nil).arg == "find it")
        #expect(tool("Grep", input: #"{"pattern":"x"}"#, result: toolResult(#""boom""#, isError: true)).mark == "error")
    }

    @Test func smallImageInlineLargeImagePlaceholder() {
        func image(_ bytes: Int) -> ControlTranscriptItem? {
            let data = Data(repeating: 7, count: bytes).base64EncodedString()
            return items(#"{"type":"user","uuid":"u1","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(data)"}}]}}"#).first
        }
        let small = image(2048)
        #expect(small?.kind == "image")
        #expect(small?.data == Data(repeating: 7, count: 2048).base64EncodedString())
        #expect(small?.bytes == 2048)
        let large = image(40960)
        #expect(large?.data == nil)
        #expect(large?.bytes == 40960)
        #expect(large?.mediaType == "image/png")
    }

    @Test func systemAndHookRecords() {
        let compact = items(#"{"type":"system","subtype":"compact_boundary","uuid":"s1","parentUuid":null,"logicalParentUuid":"a1","content":"Conversa"# +
                #"tion compacted","compactMetadata":{"trigger":"auto","preTokens":9}}"#)
        #expect(compact.map(\.kind) == ["compact"])
        #expect(compact.first?.trigger == "auto")
        let warning = items(#"{"type":"system","subtype":"informational","uuid":"s1","content":"Unknown command: /cos","level":"warning"}"#)
        #expect(warning.map(\.kind) == ["notice"])
        #expect(warning.first?.text == "Unknown command: /cos")
        #expect(warning.first?.level == "warning")
        #expect(items(#"{"type":"system","subtype":"informational","uuid":"s1","content":"fyi","level":"info"}"#).isEmpty)
        let away = items(#"{"type":"system","subtype":"away_summary","uuid":"s1","content":"While you were away","isMeta":false}"#)
        #expect(away.map(\.kind) == ["notice"])
        #expect(away.first?.text == "While you were away")
        let stop = items(#"{"type":"system","subtype":"stop_hook_summary","uuid":"s1","hookCount":2,"hookErrors":["Hook evaluator API error"],"level":"suggestion"}"#)
        #expect(stop.map(\.kind) == ["hook"])
        #expect(stop.first?.text == "Hook evaluator API error")
        #expect(items(#"{"type":"system","subtype":"stop_hook_summary","uuid":"s1","hookCount":2,"hookErrors":[],"level":"suggestion"}"#).isEmpty)
        let failed = items(#"{"type":"attachment","uuid":"h1","attachment":{"type":"hook_non_blocking_error","hookName":"Stop","stderr":"limit hit","stdout":"","exitCode":1}}"#)
        #expect(failed.map(\.kind) == ["hook"])
        #expect(failed.first?.text == "Stop: limit hit")
        #expect(items(#"{"type":"attachment","uuid":"h1","attachment":{"type":"hook_success","hookName":"SessionStart:startup","stdout":"ok","exitCode":0}}"#).isEmpty)
    }

    @Test func apiErrorBecomesError() {
        let list = items(#"{"type":"assistant","uuid":"a1","isApiErrorMessage":true,"error":"authentication_failed","message":{"id":"x","model":"<s"# +
                #"ynthetic>","content":[{"type":"text","text":"Please run /login · API Error: 403"}]}}"#)
        #expect(list.map(\.kind) == ["error"])
        #expect(list.first?.text == "Please run /login · API Error: 403")
    }

    @Test func itemNeverExceeds16KiB() {
        let body = String(repeating: "\"q\"/\n", count: 8192)
        let escaped = String(decoding: try! JSONEncoder().encode(body), as: UTF8.self)
        let list = items(#"{"type":"assistant","uuid":"a1","message":{"id":"msg_1","content":[{"type":"text","text":\#(escaped)}]}}"#)
        #expect(list.count == 1)
        #expect(try! JSONEncoder().encode(list[0]).count <= 16384)
        #expect(list[0].clipped == true)
        let typed = items(#"{"type":"user","uuid":"u1","message":{"role":"user","content":"\#(String(repeating: "ж", count: 20000))"}}"#)
        #expect(try! JSONEncoder().encode(typed[0]).count <= 16384)
        #expect(typed[0].clipped == true)
    }

    @Test func secondBlockInARecordGetsSuffixedUUID() {
        let png = Data(repeating: 1, count: 16).base64EncodedString()
        let block = #"{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(png)"}}"#
        let list = items(#"{"type":"user","uuid":"u1","message":{"role":"user","content":[\#(block),\#(block)]}}"#)
        #expect(list.map(\.uuid) == ["u1", "u1#1"])
    }

    @Test func unknownRecordsYieldNothing() {
        #expect(items(#"{"type":"api-request-shape","uuid":"x"}"#).isEmpty)
        #expect(items(#"{"type":"attachment","uuid":"x","attachment":{"type":"skill_listing"}}"#).isEmpty)
        #expect(items(#"{"type":"user","message":{"role":"user","content":"no uuid"}}"#).isEmpty)
    }
}
