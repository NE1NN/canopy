import CoreServices
import Foundation

/// Recursive FSEvents watch on a set of folders. Delivers file-level event paths on a private queue.
public final class DirectoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "canopy.directory-watcher")

    /// What the stream calls. The stream holds its own reference, so a callback already running when the
    /// watcher is released never touches freed memory.
    private final class Handler: Sendable {
        let onChange: @Sendable ([String]) -> Void

        init(_ onChange: @escaping @Sendable ([String]) -> Void) {
            self.onChange = onChange
        }
    }

    public init(paths: [String], latency: TimeInterval = 0.1, onChange: @escaping @Sendable ([String]) -> Void) {
        let handler = Handler(onChange)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Handler>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Handler>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            handler.onChange(Array(paths.prefix(count)))
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        // Swift may release the handler after its last use, which would be before the stream retains it.
        let created = withExtendedLifetime(handler) {
            FSEventStreamCreate(
                nil,
                callback,
                &context,
                paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                flags
            )
        }
        guard let stream = created else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
