import agtermCore
import AppKit
import Foundation
import Observation

/// The agterm Mobile relay run as the app's child (`agtermctl mobile serve`), one for all windows. It is off
/// until switched on, and starts again at launch while on. The relay itself lives in agtermctlKit.
@MainActor @Observable
final class PhoneRelay {
    private(set) var state: PhoneDesktopState
    /// The links serve printed, best host first; empty while not listening.
    private(set) var links: [String] = []
    /// Why the relay is not listening.
    private(set) var error: String?
    /// A failure that leaves the relay as it was: a revoke or a save.
    private(set) var notice: String?
    private(set) var lastEvent: String?

    /// A phone connected, left or was refused; the app emits it as a `phone.*` control event.
    @ObservationIgnored var onEvent: ((ControlEventKind, String) -> Void)?
    @ObservationIgnored private let stateDirectory: URL
    @ObservationIgnored private let tool: URL?
    @ObservationIgnored private var socketPath: String?
    @ObservationIgnored private var process: Process?
    /// Children sent SIGTERM and not yet gone; quit waits for them too.
    @ObservationIgnored private var ending: [Process] = []
    /// The queued stop-then-start, so a new child never binds before the old one has exited.
    @ObservationIgnored private var transition: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastStderr: String?

    /// Longer than serve's own wait for the app to answer its grid resets on SIGTERM.
    static let exitGrace: Duration = .seconds(5)

    init(stateDirectory: URL, tool: URL? = CLIInstaller.bundledTool) {
        self.stateDirectory = stateDirectory
        self.tool = tool
        state = PhoneDesktopState.load(stateDirectory: stateDirectory)
    }

    /// Called once the control socket is bound; starts the relay when it was left on.
    func attach(socketPath: String?) {
        guard self.socketPath == nil else { return }
        self.socketPath = socketPath
        if state.on { restart() }
    }

    var offeredHosts: [String] { links.compactMap(PhonePairLink.host(of:)) }
    var host: String { state.host.isEmpty ? offeredHosts.first ?? "" : state.host }
    var link: String? { links.first.map { PhonePairLink.withHost($0, host: host) } }

    var status: ControlPhoneStatus {
        ControlPhoneStatus(on: state.on, listening: !links.isEmpty, port: state.port, host: host, hosts: offeredHosts,
                           lastEvent: lastEvent, error: error, link: link)
    }

    /// Waits, without blocking main, until the queued change has run and the relay printed its links or stopped.
    func untilListening(within limit: Duration) async {
        let deadline = ContinuousClock.now + limit
        await settled()
        while state.on, links.isEmpty, error == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// On means "try to be listening": switching on a relay that is on but failed starts it again.
    func setOn(_ on: Bool) {
        guard on != state.on || (on && error != nil) else { return }
        if on != state.on {
            state.on = on
            save()
        }
        restart()
    }

    func setPort(_ port: Int) {
        guard PhoneDesktopState.portRange.contains(port), port != state.port else { return }
        state.port = port
        save()
        if state.on { restart() }
    }

    func setHost(_ host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        let value = trimmed == offeredHosts.first ? "" : trimmed // the network's best guess follows the network
        guard value != state.host else { return }
        state.host = value
        save()
    }

    /// Writes a new token, which cuts every paired phone off, then restarts serve so it shows the new code.
    /// Returns this revoke's own failure, nil on success: `notice` shows it too, but a save can overwrite it meanwhile.
    @discardableResult
    func revoke() async -> String? {
        if let failure = await Self.run(["mobile", "reset"], tool: tool, stateDirectory: stateDirectory) {
            notice = failure
            return failure
        }
        notice = nil
        if state.on { restart() }
        lastEvent = "paired phones revoked"
        return nil
    }

    /// Waits for the queued transition.
    func settled() async { await transition?.value }

    private func save() {
        do {
            try state.save(stateDirectory: stateDirectory)
            notice = nil
        } catch {
            notice = "Cannot save the phone settings: \(error.localizedDescription)"
        }
    }

    /// Ends the running child and, once it has exited, starts a new one if the relay is still on.
    private func restart() {
        generation += 1
        let ticket = generation
        links = []
        error = nil
        lastEvent = nil
        let old = process
        process = nil
        if let old { old.terminate(); ending.append(old) }
        let previous = transition
        transition = Task { [weak self] in
            await previous?.value
            if let old { await Self.waitForExit(old) }
            guard let self else { return }
            self.ending.removeAll { $0 === old }
            guard ticket == self.generation, self.state.on else { return }
            self.launch()
        }
    }

    /// SIGTERM was sent; wait without blocking main (the app must answer serve's grid resets), then SIGKILL.
    private static func waitForExit(_ child: Process) async {
        if await exited(child, within: exitGrace) { return }
        kill(child.processIdentifier, SIGKILL)
        _ = await exited(child, within: .seconds(2))
    }

    private static func exited(_ child: Process, within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while child.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return !child.isRunning
    }

    /// At quit: SIGTERM every child, then run the main run loop so the control socket keeps answering the
    /// relay's grid resets, bounded by `exitGrace`; SIGKILL what is left.
    func stopForQuit() {
        generation += 1 // the queued transition then starts nothing; cancelling it would make its sleeps spin
        let children = ending + [process].compactMap { $0 }
        process = nil
        ending = []
        children.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(TimeInterval(Self.exitGrace.components.seconds))
        while children.contains(where: \.isRunning), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        children.filter(\.isRunning).forEach { kill($0.processIdentifier, SIGKILL) }
    }

    private func launch() {
        lastStderr = nil
        guard let socketPath else { error = "The control socket is not available."; return }
        guard let tool else { error = "agtermctl is not bundled in this build."; return }
        let run = generation
        let child = Process()
        child.executableURL = tool
        child.arguments = ["mobile", "serve", "--no-qr", "--socket", socketPath, "--port", String(state.port)]
        child.environment = Self.environment(stateDirectory)
        let out = Pipe(), err = Pipe()
        child.standardOutput = out
        child.standardError = err
        child.standardInput = FileHandle.nullDevice
        Self.readLines(out, { [weak self] line in self?.stdout(line, run: run) }, atEnd: {})
        // stderr's end, not `terminationHandler`, marks the exit: it arrives after the last error line
        Self.readLines(err, { [weak self] line in self?.stderr(line, run: run) },
                       atEnd: { [weak self] in self?.exited(run: run) })
        do {
            try child.run()
            process = child
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            self.error = "Cannot run \(tool.path): \(error.localizedDescription)"
        }
    }

    private func stdout(_ line: String, run: Int) {
        guard run == generation, let link = PhoneRelayLine.link(line) else { return }
        links.append(link)
    }

    private func stderr(_ line: String, run: Int) {
        guard run == generation, let parsed = PhoneRelayLine.stderr(line) else { return }
        switch parsed {
        case .event(let text):
            lastEvent = text
            lastStderr = text
            if let event = PhoneRelayLine.controlEvent(text) { onEvent?(event.kind, event.ip) }
        case .other(let text): lastStderr = text
        }
    }

    private func exited(run: Int) {
        guard run == generation else { return }
        process = nil
        links = []
        error = lastStderr.flatMap { PhoneRelayLine.isEvent($0) ? nil : $0 } ?? "The relay stopped."
        lastStderr = nil
    }

    private nonisolated static func environment(_ stateDirectory: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["AGTERM_STATE_DIR"] = stateDirectory.path
        return env
    }

    /// Runs a short agtermctl command off the main thread; nil on success, else its error text.
    private nonisolated static func run(_ arguments: [String], tool: URL?, stateDirectory: URL) async -> String? {
        guard let tool else { return "agtermctl is not bundled in this build." }
        return await withCheckedContinuation { done in
            DispatchQueue.global().async {
                let child = Process()
                child.executableURL = tool
                child.arguments = arguments
                child.environment = environment(stateDirectory)
                let err = Pipe()
                child.standardError = err
                child.standardOutput = FileHandle.nullDevice
                do { try child.run() } catch {
                    return done.resume(returning: "Cannot run \(tool.path): \(error.localizedDescription)")
                }
                let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                child.waitUntilExit()
                guard child.terminationStatus != 0 else { return done.resume(returning: nil) }
                done.resume(returning: text.isEmpty ? "agtermctl \(arguments.joined(separator: " ")) failed." : text)
            }
        }
    }

    /// Whole lines from a child's pipe, delivered on the main actor. A line that never ends past 4 KiB is dropped.
    private static func readLines(_ pipe: Pipe, _ deliver: @escaping @MainActor (String) -> Void,
                                  atEnd: @escaping @MainActor () -> Void) {
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { @Sendable handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                Task { @MainActor in atEnd() }
                return
            }
            let lines = buffer.append(data)
            guard !lines.isEmpty else { return }
            Task { @MainActor in lines.forEach(deliver) }
        }
    }
}

/// Touched only from one pipe's readability handler, which FileHandle calls serially.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        if pending.count > 4096 { pending.removeAll() }
        return lines
    }
}
