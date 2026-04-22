import CloudPlaceholderDomain
import CloudPlaceholderPersistence
import Foundation

#if canImport(Darwin)
import Darwin
#endif

#if canImport(FileProvider)
import FileProvider
#endif

public struct CloudDriveRuntimeContext: Sendable {
    public let configuration: BackendConfiguration
    public let store: SQLiteMetadataStore
    public let syncEngine: SyncEngine
    public let stagingDirectory: URL
    public let cacheDirectory: URL
    public let runtimeRoot: URL
}

public struct CloudDriveSharedConfigurationStore {
    public static let appGroupID = "group.com.peiel.enterprisecloud.drive"
    public static let backendKindKey = "BackendKind"
    public static let mockServerURLKey = "MockServerURL"
    public static let sourceBookmarkDataKey = "SourceBookmarkData"
    public static let sourceDisplayNameKey = "SourceDisplayName"
    public static let domainDisplayNameKey = "DomainDisplayName"
    public static let defaultMockServerURL = "http://127.0.0.1:8787"
    public static let defaultDomainDisplayName = "Enterprise Cloud Drive"

    public init() {}

    public var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: Self.appGroupID) ?? .standard
    }

    public func loadBackendConfiguration() -> BackendConfiguration {
        let backendKind = BackendKind(
            rawValue: sharedDefaults.string(forKey: Self.backendKindKey) ?? BackendKind.localDirectory.rawValue
        ) ?? .localDirectory
        return BackendConfiguration(
            backendKind: backendKind,
            mockServerURL: sharedDefaults.string(forKey: Self.mockServerURLKey) ?? Self.defaultMockServerURL,
            sourceBookmarkData: sharedDefaults.data(forKey: Self.sourceBookmarkDataKey),
            sourceDisplayName: sharedDefaults.string(forKey: Self.sourceDisplayNameKey),
            domainDisplayName: sharedDefaults.string(forKey: Self.domainDisplayNameKey) ?? Self.defaultDomainDisplayName
        )
    }

    public func saveBackendConfiguration(_ configuration: BackendConfiguration) {
        sharedDefaults.set(configuration.backendKind.rawValue, forKey: Self.backendKindKey)
        sharedDefaults.set(configuration.mockServerURL ?? Self.defaultMockServerURL, forKey: Self.mockServerURLKey)
        sharedDefaults.set(configuration.sourceBookmarkData, forKey: Self.sourceBookmarkDataKey)
        sharedDefaults.set(configuration.sourceDisplayName, forKey: Self.sourceDisplayNameKey)
        sharedDefaults.set(configuration.domainDisplayName, forKey: Self.domainDisplayNameKey)
    }

    public func sharedContainerRoot() -> URL {
        let fileManager = FileManager.default
        let base = (
            fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID)
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        )
        return base.appendingPathComponent("EnterpriseCloudDriveShared", isDirectory: true)
    }

    public func runtimeRoot(domainIdentifier: String) throws -> URL {
        let root = sharedContainerRoot().appendingPathComponent(domainIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

public final class SecurityScopedResourceAccess: @unchecked Sendable {
    public let url: URL
    private let didStart: Bool

    public init(bookmarkData: Data) throws {
        var isStale = false
        do {
            url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw CloudPlaceholderError.bookmarkResolutionFailed(error.localizedDescription)
        }
        guard !isStale else {
            throw CloudPlaceholderError.bookmarkResolutionFailed("Bookmark data is stale")
        }
        didStart = url.startAccessingSecurityScopedResource()
        guard didStart else {
            throw CloudPlaceholderError.localSourceUnavailable("Unable to access \(url.path)")
        }
    }

    deinit {
        if didStart {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

public final class InterprocessFileLock: @unchecked Sendable {
    private let lockURL: URL

    public init(lockURL: URL) {
        self.lockURL = lockURL
    }

    public func withLock<T>(_ operation: () async throws -> T) async throws -> T {
        let fileDescriptor = try acquire()
        defer {
            _ = flock(fileDescriptor, LOCK_UN)
            _ = close(fileDescriptor)
        }
        return try await operation()
    }

    private func acquire() throws -> Int32 {
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fd = lockURL.path.withCString { path in
            open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard fd >= 0 else {
            throw CloudPlaceholderError.invalidState("Unable to open lock file at \(lockURL.path)")
        }
        guard flock(fd, LOCK_EX) == 0 else {
            _ = close(fd)
            throw CloudPlaceholderError.invalidState("Unable to lock \(lockURL.path)")
        }
        return fd
    }
}

public enum CloudDriveRuntime {
    public static let rootItemID = "root"

    public static func bootstrap(
        domainIdentifier: String,
        configurationStore: CloudDriveSharedConfigurationStore = CloudDriveSharedConfigurationStore(),
        fileManager: FileManager = .default
    ) throws -> CloudDriveRuntimeContext {
        let configuration = configurationStore.loadBackendConfiguration()
        let root = try configurationStore.runtimeRoot(domainIdentifier: domainIdentifier)
        let databaseURL = root.appendingPathComponent("state.sqlite")
        let cacheDirectory = root.appendingPathComponent("cache", isDirectory: true)
        let stagingDirectory = root.appendingPathComponent("staging", isDirectory: true)
        let store = try SQLiteMetadataStore(databaseURL: databaseURL)
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try seedRootIfNeeded(store: store, displayName: configuration.domainDisplayName)

        let remote: any RemoteAPIClient
        switch configuration.backendKind {
        case .mockServer:
            let baseURL = URL(
                string: configuration.mockServerURL ?? CloudDriveSharedConfigurationStore.defaultMockServerURL
            )!
            remote = HTTPRemoteAPIClient(baseURL: baseURL)
        case .localDirectory:
            remote = LocalDirectoryRemoteAPIClient(
                domainID: domainIdentifier,
                store: store,
                configurationStore: configurationStore,
                fileManager: fileManager
            )
        }

        let lock = InterprocessFileLock(lockURL: root.appendingPathComponent("sync.lock"))
        let syncEngine = SyncEngine(
            domainID: domainIdentifier,
            store: store,
            remote: remote,
            fileManager: fileManager,
            lock: lock
        )
        return CloudDriveRuntimeContext(
            configuration: configuration,
            store: store,
            syncEngine: syncEngine,
            stagingDirectory: stagingDirectory,
            cacheDirectory: cacheDirectory,
            runtimeRoot: root
        )
    }

    public static func seedRootIfNeeded(store: SQLiteMetadataStore, displayName: String) throws {
        let existing = try store.item(id: rootItemID)
        let now = Date()
        var root = existing ?? SyncItem(
            id: rootItemID,
            parentID: nil,
            name: displayName,
            kind: .directory,
            state: .hydrated,
            hydrated: true,
            createdAt: now,
            updatedAt: now
        )
        root.name = displayName
        root.kind = .directory
        root.state = .hydrated
        root.hydrated = true
        root.updatedAt = now
        try store.upsert(item: root)
    }
}

public actor SyncBootstrapCoordinator {
    private let domainID: String
    private let store: SQLiteMetadataStore
    private let syncEngine: SyncEngine
    private var task: Task<Void, Error>?

    public init(domainID: String, store: SQLiteMetadataStore, syncEngine: SyncEngine) {
        self.domainID = domainID
        self.store = store
        self.syncEngine = syncEngine
    }

    public func ensureInitialSync() async throws {
        if try hasCompletedInitialSync() {
            return
        }
        if let task {
            try await task.value
            return
        }
        let task = Task {
            try await syncEngine.syncDown()
        }
        self.task = task
        defer { self.task = nil }
        try await task.value
    }

    public func forceSync() async throws {
        try await syncEngine.syncDown()
    }

    private func hasCompletedInitialSync() throws -> Bool {
        guard let state = try store.syncState(domainID: domainID) else {
            return false
        }
        return state.remoteCursor != nil || state.workingSetCursor != nil
    }
}

#if canImport(FileProvider)
public enum FileProviderDomainSignaler {
    public static func signal(domainIdentifier: String, itemIdentifiers: Set<String>) async {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(domainIdentifier),
            displayName: CloudDriveSharedConfigurationStore.defaultDomainDisplayName
        )
        guard let manager = NSFileProviderManager(for: domain) else {
            return
        }
        let providerIdentifiers: Set<NSFileProviderItemIdentifier> = Set(
            itemIdentifiers.map { identifier in
                identifier == CloudDriveRuntime.rootItemID ? .rootContainer : NSFileProviderItemIdentifier(identifier)
            }
        ).union([.workingSet, .rootContainer])
        for identifier in providerIdentifiers {
            await withCheckedContinuation { continuation in
                manager.signalEnumerator(for: identifier) { _ in
                    continuation.resume()
                }
            }
        }
    }
}
#endif
