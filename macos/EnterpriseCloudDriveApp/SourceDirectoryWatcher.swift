import CloudPlaceholderSync
import CoreServices
import Foundation

final class SourceDirectoryWatcher {
    private let access: SecurityScopedResourceAccess
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "EnterpriseCloudDrive.SourceDirectoryWatcher")
    private var stream: FSEventStreamRef?

    init(bookmarkData: Data, onChange: @escaping @Sendable () -> Void) throws {
        self.access = try SecurityScopedResourceAccess(bookmarkData: bookmarkData)
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else {
            return
        }
        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
        )
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<SourceDirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.onChange()
            },
            &context,
            [access.url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    func invalidate() {
        guard let stream else {
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        invalidate()
    }
}
