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
    private(set) var error: String?
    private(set) var lastEvent: String?

    @ObservationIgnored private let stateDirectory: URL
    @ObservationIgnored private var socketPath: String?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var generation = 0

    init(stateDirectory: URL) {
        self.stateDirectory = stateDirectory
        state = PhoneDesktopState.load(stateDirectory: stateDirectory)
    }

    /// Called once the control socket is bound; starts the relay when it was left on.
    func attach(socketPath: String?) {
        guard self.socketPath == nil else { return }
        self.socketPath = socketPath
        if state.on { start() }
    }

    var offeredHosts: [String] { links.compactMap(PhonePairLink.host(of:)) }
    var host: String { state.host.isEmpty ? offeredHosts.first ?? "" : state.host }
    var link: String? { links.first.map { PhonePairLink.withHost($0, host: host) } }

    func setOn(_ on: Bool) {
        guard on != state.on else { return }
        state.on = on
        save()
        if on { start() } else { stop(); error = nil; lastEvent = nil }
    }

    func setPort(_ port: Int) {
        guard (1024...65535).contains(port), port != state.port else { return }
        state.port = port
        save()
        if state.on { start() }
    }

    func setHost(_ host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        let value = trimmed == offeredHosts.first ? "" : trimmed // the network's best guess follows the network
        guard value != state.host else { return }
        state.host = value
        save()
    }

    /// Writes a new token, which cuts every paired phone off, then restarts serve so it shows the new code.
    func revoke() {
        let result = Self.run(["mobile", "reset"], stateDirectory: stateDirectory)
        if let failure = result { error = failure; return }
        lastEvent = "Paired phones revoked."
        if state.on { start() }
    }

    private func save() {
        do { try state.save(stateDirectory: stateDirectory) } catch { self.error = "Cannot save \(error.localizedDescription)" }
    }

    private func start() {
        stop()
        error = nil
        lastEvent = nil
        guard let socketPath else { error = "The control socket is not available."; return }
        guard let tool = CLIInstaller.bundledTool else { error = "agtermctl is not bundled in this build."; return }
        generation += 1
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
            self.error = "Cannot run \(tool.path): \(error.localizedDescription)"
        }
    }

    /// SIGTERM, then SIGKILL after 2 s, so the port is free before a restart binds it again. Quit calls it too.
    func stop() {
        generation += 1
        links = []
        guard let child = process else { return }
        process = nil
        child.terminate()
        let deadline = Date().addingTimeInterval(2)
        while child.isRunning, Date() < deadline { usleep(20_000) }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
    }

    @ObservationIgnored private var lastStderr: String?

    private func stdout(_ line: String, run: Int) {
        guard run == generation, let link = PhoneRelayLine.link(line) else { return }
        links.append(link)
    }

    private func stderr(_ line: String, run: Int) {
        guard run == generation, let parsed = PhoneRelayLine.stderr(line) else { return }
        switch parsed {
        case .event(let text): lastEvent = text; lastStderr = text
        case .other(let text): lastStderr = text
        }
    }

    private func exited(run: Int) {
        guard run == generation else { return }
        process = nil
        links = []
        error = lastStderr.flatMap { $0.hasPrefix("phone connected") || $0.hasPrefix("refused ") ? nil : $0 }
            ?? "The relay stopped."
        lastStderr = nil
    }

    private static func environment(_ stateDirectory: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["AGTERM_STATE_DIR"] = stateDirectory.path
        return env
    }

    /// Runs a short agtermctl command; nil on success, else its error text.
    private static func run(_ arguments: [String], stateDirectory: URL) -> String? {
        guard let tool = CLIInstaller.bundledTool else { return "agtermctl is not bundled in this build." }
        let child = Process()
        child.executableURL = tool
        child.arguments = arguments
        child.environment = environment(stateDirectory)
        let err = Pipe()
        child.standardError = err
        child.standardOutput = FileHandle.nullDevice
        do { try child.run() } catch { return "Cannot run \(tool.path): \(error.localizedDescription)" }
        child.waitUntilExit()
        guard child.terminationStatus != 0 else { return nil }
        let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "agtermctl \(arguments.joined(separator: " ")) failed." : text
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
