import Foundation

public enum DeploymentMode: String, Codable, CaseIterable, Sendable {
    case managedCloud
    case selfHosted
}

public enum ItemKind: String, Codable, CaseIterable, Sendable {
    case file
    case directory
}

public enum ItemState: String, Codable, CaseIterable, Sendable {
    case cloudOnly
    case hydrated
    case syncing
    case dirty
    case conflict
}

public enum PendingOperationType: String, Codable, CaseIterable, Sendable {
    case create
    case modify
    case move
    case delete
}

public enum OperationLifecycleState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case failed
    case done
    case conflict
}

public enum TransferDirection: String, Codable, CaseIterable, Sendable {
    case upload
    case download
}

public enum TransferLifecycleState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case paused
    case failed
    case done
}

public struct SyncItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var parentID: String?
    public var name: String
    public var kind: ItemKind
    public var size: Int64
    public var contentHash: String?
    public var contentVersion: String?
    public var metadataVersion: String?
    public var remoteModifiedAt: Date?
    public var deleted: Bool
    public var state: ItemState
    public var hydrated: Bool
    public var pinned: Bool
    public var dirty: Bool
    public var localPath: String?
    public var lastUsedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        parentID: String?,
        name: String,
        kind: ItemKind,
        size: Int64 = 0,
        contentHash: String? = nil,
        contentVersion: String? = nil,
        metadataVersion: String? = nil,
        remoteModifiedAt: Date? = nil,
        deleted: Bool = false,
        state: ItemState = .cloudOnly,
        hydrated: Bool = false,
        pinned: Bool = false,
        dirty: Bool = false,
        localPath: String? = nil,
        lastUsedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.kind = kind
        self.size = size
        self.contentHash = contentHash
        self.contentVersion = contentVersion
        self.metadataVersion = metadataVersion
        self.remoteModifiedAt = remoteModifiedAt
        self.deleted = deleted
        self.state = state
        self.hydrated = hydrated
        self.pinned = pinned
        self.dirty = dirty
        self.localPath = localPath
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct SyncCursorState: Codable, Equatable, Sendable {
    public var domainID: String
    public var remoteCursor: String?
    public var workingSetCursor: String?
    public var lastFullSyncAt: Date?
    public var lastPushAt: Date?

    public init(
        domainID: String,
        remoteCursor: String? = nil,
        workingSetCursor: String? = nil,
        lastFullSyncAt: Date? = nil,
        lastPushAt: Date? = nil
    ) {
        self.domainID = domainID
        self.remoteCursor = remoteCursor
        self.workingSetCursor = workingSetCursor
        self.lastFullSyncAt = lastFullSyncAt
        self.lastPushAt = lastPushAt
    }
}

public struct PendingOperation: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var itemID: String
    public var type: PendingOperationType
    public var baseContentVersion: String?
    public var baseMetadataVersion: String?
    public var payloadJSON: String
    public var state: OperationLifecycleState
    public var retryCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        itemID: String,
        type: PendingOperationType,
        baseContentVersion: String? = nil,
        baseMetadataVersion: String? = nil,
        payloadJSON: String,
        state: OperationLifecycleState = .queued,
        retryCount: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.itemID = itemID
        self.type = type
        self.baseContentVersion = baseContentVersion
        self.baseMetadataVersion = baseMetadataVersion
        self.payloadJSON = payloadJSON
        self.state = state
        self.retryCount = retryCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct TransferRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var itemID: String
    public var direction: TransferDirection
    public var tempPath: String
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public var resumeToken: String?
    public var state: TransferLifecycleState
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        itemID: String,
        direction: TransferDirection,
        tempPath: String,
        bytesDone: Int64 = 0,
        bytesTotal: Int64 = 0,
        resumeToken: String? = nil,
        state: TransferLifecycleState = .queued,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.itemID = itemID
        self.direction = direction
        self.tempPath = tempPath
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.resumeToken = resumeToken
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ContentCacheRecord: Codable, Equatable, Sendable {
    public var itemID: String
    public var localFilePath: String
    public var materializedSize: Int64
    public var checksum: String?
    public var evictable: Bool
    public var lastVerifiedAt: Date?

    public init(
        itemID: String,
        localFilePath: String,
        materializedSize: Int64,
        checksum: String? = nil,
        evictable: Bool = true,
        lastVerifiedAt: Date? = nil
    ) {
        self.itemID = itemID
        self.localFilePath = localFilePath
        self.materializedSize = materializedSize
        self.checksum = checksum
        self.evictable = evictable
        self.lastVerifiedAt = lastVerifiedAt
    }
}

public struct DevicePolicy: Codable, Equatable, Sendable {
    public var maxFileSizeBytes: Int64
    public var totalQuotaBytes: Int64
    public var offlineCacheLimitBytes: Int64
    public var allowedDeviceIDs: [String]

    public init(
        maxFileSizeBytes: Int64 = 100 * 1024 * 1024 * 1024,
        totalQuotaBytes: Int64 = 500 * 1024 * 1024 * 1024,
        offlineCacheLimitBytes: Int64 = 50 * 1024 * 1024 * 1024,
        allowedDeviceIDs: [String] = []
    ) {
        self.maxFileSizeBytes = maxFileSizeBytes
        self.totalQuotaBytes = totalQuotaBytes
        self.offlineCacheLimitBytes = offlineCacheLimitBytes
        self.allowedDeviceIDs = allowedDeviceIDs
    }
}

public struct RemoteChangeBatch: Codable, Equatable, Sendable {
    public var items: [SyncItem]
    public var deletedItemIDs: [String]
    public var nextCursor: String
    public var hasMore: Bool

    public init(items: [SyncItem], deletedItemIDs: [String], nextCursor: String, hasMore: Bool) {
        self.items = items
        self.deletedItemIDs = deletedItemIDs
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public struct UploadDescriptor: Codable, Equatable, Sendable {
    public var operationID: String
    public var itemID: String
    public var parentID: String?
    public var fileName: String
    public var fileSize: Int64
    public var sha256: String
    public var baseContentVersion: String?
    public var baseMetadataVersion: String?

    public init(
        operationID: String,
        itemID: String,
        parentID: String? = nil,
        fileName: String,
        fileSize: Int64,
        sha256: String,
        baseContentVersion: String?,
        baseMetadataVersion: String?
    ) {
        self.operationID = operationID
        self.itemID = itemID
        self.parentID = parentID
        self.fileName = fileName
        self.fileSize = fileSize
        self.sha256 = sha256
        self.baseContentVersion = baseContentVersion
        self.baseMetadataVersion = baseMetadataVersion
    }
}

public struct RemoteCommitResult: Codable, Equatable, Sendable {
    public var item: SyncItem
    public var remoteCursor: String

    public init(item: SyncItem, remoteCursor: String) {
        self.item = item
        self.remoteCursor = remoteCursor
    }
}

public struct DeviceRegistration: Codable, Equatable, Sendable {
    public var tenantID: String
    public var userID: String
    public var deviceID: String
    public var hostName: String
    public var deploymentMode: DeploymentMode

    public init(
        tenantID: String,
        userID: String,
        deviceID: String,
        hostName: String,
        deploymentMode: DeploymentMode
    ) {
        self.tenantID = tenantID
        self.userID = userID
        self.deviceID = deviceID
        self.hostName = hostName
        self.deploymentMode = deploymentMode
    }
}

public struct AuditEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var tenantID: String
    public var actorID: String
    public var itemID: String?
    public var action: String
    public var happenedAt: Date
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        tenantID: String,
        actorID: String,
        itemID: String? = nil,
        action: String,
        happenedAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.tenantID = tenantID
        self.actorID = actorID
        self.itemID = itemID
        self.action = action
        self.happenedAt = happenedAt
        self.metadata = metadata
    }
}

public enum CloudPlaceholderError: Error, Equatable, LocalizedError, Sendable {
    case sqlite(String)
    case missingItem(String)
    case invalidState(String)
    case versionConflict(String)
    case ignoredSystemFile(String)
    case network(String)
    case localSourceUnavailable(String)
    case bookmarkResolutionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sqlite(let message):
            return "SQLite error: \(message)"
        case .missingItem(let itemID):
            return "Missing item: \(itemID)"
        case .invalidState(let message):
            return "Invalid state: \(message)"
        case .versionConflict(let itemID):
            return "Version conflict for item: \(itemID)"
        case .ignoredSystemFile(let path):
            return "Ignored system file: \(path)"
        case .network(let message):
            return "Network error: \(message)"
        case .localSourceUnavailable(let message):
            return "Local source unavailable: \(message)"
        case .bookmarkResolutionFailed(let message):
            return "Bookmark resolution failed: \(message)"
        }
    }
}

public protocol MetadataStore: Sendable {
    func bootstrap() throws
    func upsert(item: SyncItem) throws
    func item(id: String) throws -> SyncItem?
    func children(of parentID: String?) throws -> [SyncItem]
    func tombstone(itemID: String, updatedAt: Date) throws
    func updatePinned(itemID: String, pinned: Bool, updatedAt: Date) throws
    func markHydrated(itemID: String, localPath: String, size: Int64, checksum: String?, lastUsedAt: Date) throws
    func markCloudOnly(itemID: String, updatedAt: Date) throws
    func markState(itemID: String, state: ItemState, dirty: Bool, updatedAt: Date) throws
    func recordUse(itemID: String, at: Date) throws
    func evictionCandidates(limit: Int) throws -> [SyncItem]
    func totalCachedBytes() throws -> Int64
    func save(syncState: SyncCursorState) throws
    func syncState(domainID: String) throws -> SyncCursorState?
    func enqueue(_ operation: PendingOperation) throws
    func pendingOperations(in states: [OperationLifecycleState]) throws -> [PendingOperation]
    func updateOperationState(id: String, state: OperationLifecycleState, retryCount: Int, updatedAt: Date) throws
    func save(transfer: TransferRecord) throws
    func transfer(id: String) throws -> TransferRecord?
    func appendProviderChanges(domainID: String, changes: [ProviderChange]) throws -> Int64
    func providerChanges(domainID: String, after sequence: Int64, containerID: String?) throws -> [ProviderChange]
    func latestProviderChangeSequence(domainID: String) throws -> Int64
}

public protocol RemoteAPIClient: Sendable {
    var requiresPostMutationSync: Bool { get }
    func register(device: DeviceRegistration) async throws -> DevicePolicy
    func fetchChanges(cursor: String?) async throws -> RemoteChangeBatch
    func downloadContent(itemID: String, to destinationURL: URL) async throws -> SyncItem
    func uploadContent(descriptor: UploadDescriptor, fileURL: URL) async throws -> RemoteCommitResult
    func createDirectory(itemID: String, parentID: String?, name: String, baseMetadataVersion: String?) async throws -> RemoteCommitResult
    func updateMetadata(itemID: String, name: String, parentID: String?, baseMetadataVersion: String?) async throws -> RemoteCommitResult
    func deleteItem(itemID: String, baseMetadataVersion: String?) async throws -> String
}

public enum IgnoredSystemFileMatcher {
    private static let exactNames: Set<String> = [
        ".DS_Store",
        ".TemporaryItems",
        ".Trashes"
    ]

    public static func shouldIgnore(filename: String) -> Bool {
        if exactNames.contains(filename) {
            return true
        }
        if filename.hasPrefix("._") {
            return true
        }
        if filename.hasPrefix("~$") {
            return true
        }
        if filename.hasSuffix(".swp") || filename.hasSuffix(".tmp") {
            return true
        }
        return false
    }
}
