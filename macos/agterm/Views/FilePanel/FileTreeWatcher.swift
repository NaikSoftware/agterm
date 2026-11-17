import CoreServices
import Foundation

/// Reports changed paths under `root` on the main actor, batched by FSEvents.
final class FileTreeWatcher {
    // The stream retains the sink through its context, so a callback in flight after `stop` never reads freed memory.
    private final class Sink: Sendable {
        let onChange: @MainActor @Sendable ([String]) -> Void
        init(_ onChange: @escaping @MainActor @Sendable ([String]) -> Void) { self.onChange = onChange }
    }

    private static let queue = DispatchQueue(label: "com.umputun.agterm.file-tree-watcher")
    private var stream: FSEventStreamRef?

    init(root: URL, onChange: @escaping @MainActor @Sendable ([String]) -> Void) {
        let sink = Unmanaged.passRetained(Sink(onChange))
        defer { sink.release() }
        var context = FSEventStreamContext(
            version: 0, info: sink.toOpaque(),
            retain: { UnsafeRawPointer(Unmanaged<Sink>.fromOpaque($0!).retain().toOpaque()) },
            release: { Unmanaged<Sink>.fromOpaque($0!).release() },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let sink = Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            Task { @MainActor in sink.onChange(changed) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, Self.queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit { stop() }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
