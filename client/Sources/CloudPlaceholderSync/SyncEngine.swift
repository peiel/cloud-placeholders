import CloudPlaceholderDomain
import CloudPlaceholderPersistence
import CryptoKit
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum PendingOperationPayloadType: String, Codable, Sendable {
    case fileWrite
    case createDirectory
    case updateMetadata
    case deleteItem
}

public struct PendingOperationPayload: Codable, Equatable, Sendable {
    public var type: PendingOperationPayloadType
    public var filePath: String?
    public var fileName: String?
    public var fileSize: Int64?
    public var sha256: String?
    public var name: String?
    public var parentID: String?

    public init(
        type: PendingOperationPayloadType,
        filePath: String? = nil,
        fileName: String? = nil,
        fileSize: Int64? = nil,
        sha256: String? = nil,
        name: String? = nil,
        parentID: String? = nil
    ) {
        self.type = type
        self.filePath = filePath
        self.fileName = fileName
        self.fileSize = fileSize
        self.sha256 = sha256
        self.name = name
        self.parentID = parentID
    }
}

public final class SyncEngine: @unchecked Sendable {
    private let store: MetadataStore
    private let remote: RemoteAPIClient
    private let fileManager: FileManager
    private let domainID: String
    private let lock: InterprocessFileLock?

    public init(
        domainID: String,
        store: MetadataStore,
        remote: RemoteAPIClient,
        fileManager: FileManager = .default,
        lock: InterprocessFileLock? = nil
    ) {
        self.domainID = domainID
        self.store = store
        self.remote = remote
        self.fileManager = fileManager
        self.lock = lock
    }

    @discardableResult
    public func register(device: DeviceRegistration) async throws -> DevicePolicy {
        try await remote.register(device: device)
    }

    public func syncDown() async throws {
        try await withSynchronizationLock {
            var cursorState = try store.syncState(domainID: domainID) ?? SyncCursorState(domainID: domainID)
            var nextCursor = cursorState.remoteCursor
            var latestWorkingSet = try store.latestProviderChangeSequence(domainID: domainID)
            repeat {
                let batch = try await remote.fetchChanges(cursor: nextCursor)
                let now = Date()
                var providerChanges: [ProviderChange] = []
                for item in batch.items {
                    let previous = try store.item(id: item.id)
                    let merged = mergeRemoteItem(item, with: previous)
                    try store.upsert(item: merged)
                    providerChanges.append(
                        ProviderChange(
                            domainID: domainID,
                            itemID: merged.id,
                            parentItemID: merged.parentID,
                            previousParentItemID: previous?.parentID,
                            changeType: .update,
                            deleted: false,
                            changedAt: now
                        )
                    )
                }
                for deletedID in batch.deletedItemIDs {
                    let previous = try store.item(id: deletedID)
                    let deletedItems = try tombstoneSubtree(itemID: deletedID, updatedAt: now)
                    if deletedItems.isEmpty {
                        providerChanges.append(
                            ProviderChange(
                                domainID: domainID,
                                itemID: deletedID,
                                parentItemID: previous?.parentID,
                                previousParentItemID: previous?.parentID,
                                changeType: .delete,
                                deleted: true,
                                changedAt: now
                            )
                        )
                    } else {
                        providerChanges.append(
                            contentsOf: deletedItems.map { deletedItem in
                                ProviderChange(
                                    domainID: domainID,
                                    itemID: deletedItem.id,
                                    parentItemID: deletedItem.parentID,
                                    previousParentItemID: deletedItem.parentID,
                                    changeType: .delete,
                                    deleted: true,
                                    changedAt: now
                                )
                            }
                        )
                    }
                }
                if !providerChanges.isEmpty {
                    latestWorkingSet = try store.appendProviderChanges(domainID: domainID, changes: providerChanges)
                }
                nextCursor = batch.nextCursor
                cursorState.remoteCursor = batch.nextCursor
                cursorState.workingSetCursor = String(latestWorkingSet)
                cursorState.lastFullSyncAt = now
                try store.save(syncState: cursorState)
                if !batch.hasMore {
                    break
                }
            } while true
        }
    }

    @discardableResult
    public func materializeItem(itemID: String, cacheDirectory: URL) async throws -> URL {
        guard var item = try store.item(id: itemID) else {
            throw CloudPlaceholderError.missingItem(itemID)
        }
        if item.hydrated, let localPath = item.localPath, fileManager.fileExists(atPath: localPath) {
            try store.recordUse(itemID: itemID, at: Date())
            return URL(fileURLWithPath: localPath)
        }

        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let tempURL = cacheDirectory.appendingPathComponent("\(itemID).downloading")
        let finalURL = cacheDirectory.appendingPathComponent(makeMaterializedFileName(item: item))
        let transfer = TransferRecord(
            itemID: itemID,
            direction: .download,
            tempPath: tempURL.path,
            state: .running
        )
        try store.save(transfer: transfer)

        let downloadedItem = try await remote.downloadContent(itemID: itemID, to: tempURL)
        if fileManager.fileExists(atPath: finalURL.path) {
            try fileManager.removeItem(at: finalURL)
        }
        try fileManager.moveItem(at: tempURL, to: finalURL)

        item = downloadedItem
        item.hydrated = true
        item.localPath = finalURL.path
        item.state = .hydrated
        item.lastUsedAt = Date()
        item.updatedAt = Date()
        try store.upsert(item: item)
        try store.markHydrated(
            itemID: itemID,
            localPath: finalURL.path,
            size: item.size,
            checksum: item.contentHash,
            lastUsedAt: Date()
        )
        try store.save(
            transfer: TransferRecord(
                id: transfer.id,
                itemID: transfer.itemID,
                direction: transfer.direction,
                tempPath: transfer.tempPath,
                bytesDone: item.size,
                bytesTotal: item.size,
                resumeToken: nil,
                state: .done,
                createdAt: transfer.createdAt,
                updatedAt: Date()
            )
        )
        return finalURL
    }

    @discardableResult
    public func stageLocalFile(itemID: String, parentID: String?, fileURL: URL) throws -> PendingOperation {
        if IgnoredSystemFileMatcher.shouldIgnore(filename: fileURL.lastPathComponent) {
            throw CloudPlaceholderError.ignoredSystemFile(fileURL.lastPathComponent)
        }
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let sha256 = try sha256Hex(for: fileURL)
        let now = Date()

        var item = try store.item(id: itemID) ?? SyncItem(
            id: itemID,
            parentID: parentID,
            name: fileURL.lastPathComponent,
            kind: .file,
            size: fileSize,
            contentHash: sha256,
            state: .dirty,
            hydrated: true,
            pinned: false,
            dirty: true,
            localPath: fileURL.path,
            createdAt: now,
            updatedAt: now
        )
        item.parentID = parentID
        item.name = fileURL.lastPathComponent
        item.size = fileSize
        item.contentHash = sha256
        item.state = .dirty
        item.hydrated = true
        item.dirty = true
        item.localPath = fileURL.path
        item.lastUsedAt = now
        item.updatedAt = now
        try store.upsert(item: item)
        try store.markState(itemID: itemID, state: .dirty, dirty: true, updatedAt: now)

        let payload = PendingOperationPayload(
            type: .fileWrite,
            filePath: fileURL.path,
            fileName: fileURL.lastPathComponent,
            fileSize: fileSize,
            sha256: sha256,
            parentID: parentID
        )
        let payloadData = try JSONEncoder().encode(payload)
        let operation = PendingOperation(
            itemID: itemID,
            type: item.contentVersion == nil ? .create : .modify,
            baseContentVersion: item.contentVersion,
            baseMetadataVersion: item.metadataVersion,
            payloadJSON: String(decoding: payloadData, as: UTF8.self),
            state: .queued,
            retryCount: 0,
            createdAt: now,
            updatedAt: now
        )
        try store.enqueue(operation)
        return operation
    }

    @discardableResult
    public func stageDirectoryCreation(itemID: String, parentID: String?, name: String) throws -> PendingOperation {
        let now = Date()
        try store.upsert(
            item: SyncItem(
                id: itemID,
                parentID: parentID,
                name: name,
                kind: .directory,
                state: .dirty,
                hydrated: true,
                dirty: true,
                createdAt: now,
                updatedAt: now
            )
        )
        let payload = PendingOperationPayload(type: .createDirectory, name: name, parentID: parentID)
        let data = try JSONEncoder().encode(payload)
        let operation = PendingOperation(
            itemID: itemID,
            type: .create,
            payloadJSON: String(decoding: data, as: UTF8.self),
            createdAt: now,
            updatedAt: now
        )
        try store.enqueue(operation)
        return operation
    }

    @discardableResult
    public func stageMetadataChange(itemID: String, parentID: String?, name: String) throws -> PendingOperation {
        let now = Date()
        if var item = try store.item(id: itemID) {
            item.parentID = parentID
            item.name = name
            item.state = .dirty
            item.dirty = true
            item.updatedAt = now
            try store.upsert(item: item)
        }
        let payload = PendingOperationPayload(type: .updateMetadata, name: name, parentID: parentID)
        let data = try JSONEncoder().encode(payload)
        let current = try store.item(id: itemID)
        let operation = PendingOperation(
            itemID: itemID,
            type: .move,
            baseContentVersion: current?.contentVersion,
            baseMetadataVersion: current?.metadataVersion,
            payloadJSON: String(decoding: data, as: UTF8.self),
            createdAt: now,
            updatedAt: now
        )
        try store.enqueue(operation)
        return operation
    }

    @discardableResult
    public func stageDeletion(itemID: String) throws -> PendingOperation {
        let now = Date()
        let current = try store.item(id: itemID)
        let payload = PendingOperationPayload(type: .deleteItem)
        let data = try JSONEncoder().encode(payload)
        let operation = PendingOperation(
            itemID: itemID,
            type: .delete,
            baseContentVersion: current?.contentVersion,
            baseMetadataVersion: current?.metadataVersion,
            payloadJSON: String(decoding: data, as: UTF8.self),
            createdAt: now,
            updatedAt: now
        )
        try store.enqueue(operation)
        return operation
    }

    public func flushPendingOperations() async throws {
        try await withSynchronizationLock {
            let operations = try store.pendingOperations(in: [.queued, .failed])
            for operation in operations {
                try store.updateOperationState(
                    id: operation.id,
                    state: .running,
                    retryCount: operation.retryCount,
                    updatedAt: Date()
                )
                do {
                    let payload = try JSONDecoder().decode(
                        PendingOperationPayload.self,
                        from: Data(operation.payloadJSON.utf8)
                    )
                    try await apply(operation: operation, payload: payload)
                    try store.updateOperationState(id: operation.id, state: .done, retryCount: operation.retryCount, updatedAt: Date())
                } catch let error as CloudPlaceholderError {
                    switch error {
                    case .versionConflict:
                        try store.markState(itemID: operation.itemID, state: .conflict, dirty: true, updatedAt: Date())
                        try store.updateOperationState(id: operation.id, state: .conflict, retryCount: operation.retryCount, updatedAt: Date())
                    default:
                        try store.updateOperationState(id: operation.id, state: .failed, retryCount: operation.retryCount + 1, updatedAt: Date())
                    }
                } catch {
                    try store.updateOperationState(id: operation.id, state: .failed, retryCount: operation.retryCount + 1, updatedAt: Date())
                }
            }
        }
    }

    public func flushPendingUploads() async throws {
        try await flushPendingOperations()
    }

    private func apply(operation: PendingOperation, payload: PendingOperationPayload) async throws {
        switch payload.type {
        case .fileWrite:
            try await applyFileWrite(operation: operation, payload: payload)
        case .createDirectory:
            try await applyCreateDirectory(operation: operation, payload: payload)
        case .updateMetadata:
            try await applyMetadataUpdate(operation: operation, payload: payload)
        case .deleteItem:
            try await applyDeletion(operation: operation)
        }
    }

    private func applyFileWrite(operation: PendingOperation, payload: PendingOperationPayload) async throws {
        guard
            let filePath = payload.filePath,
            let fileName = payload.fileName,
            let fileSize = payload.fileSize,
            let sha256 = payload.sha256
        else {
            throw CloudPlaceholderError.invalidState("Missing file payload for \(operation.itemID)")
        }
        let previous = try store.item(id: operation.itemID)
        let descriptor = UploadDescriptor(
            operationID: operation.id,
            itemID: operation.itemID,
            parentID: payload.parentID,
            fileName: fileName,
            fileSize: fileSize,
            sha256: sha256,
            baseContentVersion: operation.baseContentVersion,
            baseMetadataVersion: operation.baseMetadataVersion
        )
        let result = try await remote.uploadContent(
            descriptor: descriptor,
            fileURL: URL(fileURLWithPath: filePath)
        )
        var item = mergeRemoteItem(result.item, with: previous)
        item.localPath = filePath
        item.hydrated = true
        item.dirty = false
        item.state = .hydrated
        item.lastUsedAt = Date()
        item.updatedAt = Date()
        try store.upsert(item: item)
        try store.markHydrated(
            itemID: item.id,
            localPath: filePath,
            size: fileSize,
            checksum: sha256,
            lastUsedAt: Date()
        )
        try recordMutation(
            remoteCursor: result.remoteCursor,
            item: item,
            previousParentID: previous?.parentID,
            deleted: false
        )
    }

    private func applyCreateDirectory(operation: PendingOperation, payload: PendingOperationPayload) async throws {
        guard let name = payload.name else {
            throw CloudPlaceholderError.invalidState("Missing directory name for \(operation.itemID)")
        }
        let result = try await remote.createDirectory(
            itemID: operation.itemID,
            parentID: payload.parentID,
            name: name,
            baseMetadataVersion: operation.baseMetadataVersion
        )
        let previous = try store.item(id: operation.itemID)
        let item = mergeRemoteItem(result.item, with: previous)
        try store.upsert(item: item)
        try recordMutation(
            remoteCursor: result.remoteCursor,
            item: item,
            previousParentID: previous?.parentID,
            deleted: false
        )
    }

    private func applyMetadataUpdate(operation: PendingOperation, payload: PendingOperationPayload) async throws {
        guard let name = payload.name else {
            throw CloudPlaceholderError.invalidState("Missing metadata payload for \(operation.itemID)")
        }
        let previous = try store.item(id: operation.itemID)
        let result = try await remote.updateMetadata(
            itemID: operation.itemID,
            name: name,
            parentID: payload.parentID,
            baseMetadataVersion: operation.baseMetadataVersion
        )
        var item = mergeRemoteItem(result.item, with: previous)
        item.dirty = false
        if item.kind == .directory {
            item.hydrated = true
            item.state = .hydrated
        }
        try store.upsert(item: item)
        try recordMutation(
            remoteCursor: result.remoteCursor,
            item: item,
            previousParentID: previous?.parentID,
            deleted: false
        )
    }

    private func applyDeletion(operation: PendingOperation) async throws {
        let previous = try store.item(id: operation.itemID)
        let remoteCursor = try await remote.deleteItem(
            itemID: operation.itemID,
            baseMetadataVersion: operation.baseMetadataVersion
        )
        let deletedItems = try tombstoneSubtree(itemID: operation.itemID, updatedAt: Date())
        try recordDeletion(
            remoteCursor: remoteCursor,
            deletedItems: deletedItems.isEmpty
                ? [DeletedItem(id: operation.itemID, parentID: previous?.parentID)]
                : deletedItems
        )
    }

    private func recordMutation(
        remoteCursor: String,
        item: SyncItem,
        previousParentID: String?,
        deleted: Bool
    ) throws {
        var cursorState = try store.syncState(domainID: domainID) ?? SyncCursorState(domainID: domainID)
        let change = ProviderChange(
            domainID: domainID,
            itemID: item.id,
            parentItemID: item.parentID,
            previousParentItemID: previousParentID,
            changeType: deleted ? .delete : .update,
            deleted: deleted,
            changedAt: Date()
        )
        let sequence = try store.appendProviderChanges(domainID: domainID, changes: [change])
        cursorState.remoteCursor = remoteCursor
        cursorState.workingSetCursor = String(sequence)
        cursorState.lastPushAt = Date()
        try store.save(syncState: cursorState)
    }

    private func recordDeletion(remoteCursor: String, deletedItems: [DeletedItem]) throws {
        var cursorState = try store.syncState(domainID: domainID) ?? SyncCursorState(domainID: domainID)
        let sequence = try store.appendProviderChanges(
            domainID: domainID,
            changes: deletedItems.map { deletedItem in
                ProviderChange(
                    domainID: domainID,
                    itemID: deletedItem.id,
                    parentItemID: deletedItem.parentID,
                    previousParentItemID: deletedItem.parentID,
                    changeType: .delete,
                    deleted: true,
                    changedAt: Date()
                )
            }
        )
        cursorState.remoteCursor = remoteCursor
        cursorState.workingSetCursor = String(sequence)
        cursorState.lastPushAt = Date()
        try store.save(syncState: cursorState)
    }

    @discardableResult
    public func evictColdFiles(maximumCachedBytes: Int64) throws -> [String] {
        var evicted: [String] = []
        var totalCachedBytes = try store.totalCachedBytes()
        guard totalCachedBytes > maximumCachedBytes else {
            return evicted
        }
        let candidates = try store.evictionCandidates(limit: 100)
        for candidate in candidates {
            guard totalCachedBytes > maximumCachedBytes else {
                break
            }
            if let localPath = candidate.localPath, fileManager.fileExists(atPath: localPath) {
                try fileManager.removeItem(atPath: localPath)
            }
            try store.markCloudOnly(itemID: candidate.id, updatedAt: Date())
            totalCachedBytes -= candidate.size
            evicted.append(candidate.id)
        }
        return evicted
    }

    private func sha256Hex(for fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeMaterializedFileName(item: SyncItem) -> String {
        let safeName = item.name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return "\(item.id)-\(safeName)"
    }

    private func mergeRemoteItem(_ remoteItem: SyncItem, with existing: SyncItem?) -> SyncItem {
        guard let existing else {
            return remoteItem
        }
        var merged = remoteItem
        merged.pinned = existing.pinned
        if existing.hydrated,
           existing.localPath != nil,
           existing.contentVersion == nil || existing.contentVersion == remoteItem.contentVersion {
            merged.hydrated = true
            merged.localPath = existing.localPath
            merged.lastUsedAt = existing.lastUsedAt
            if merged.kind == .directory {
                merged.state = .hydrated
            }
        }
        return merged
    }

    private func withSynchronizationLock<T>(_ operation: () async throws -> T) async throws -> T {
        if let lock {
            return try await lock.withLock(operation)
        }
        return try await operation()
    }

    private func tombstoneSubtree(itemID: String, updatedAt: Date) throws -> [DeletedItem] {
        var queue = [itemID]
        var deletedItems: [DeletedItem] = []
        var seen: Set<String> = []

        while let currentID = queue.first {
            queue.removeFirst()
            guard seen.insert(currentID).inserted else {
                continue
            }
            guard let item = try store.item(id: currentID), !item.deleted else {
                continue
            }
            let children = try store.children(of: currentID)
            queue.append(contentsOf: children.map(\.id))
            try store.tombstone(itemID: currentID, updatedAt: updatedAt)
            deletedItems.append(DeletedItem(id: currentID, parentID: item.parentID))
        }

        return deletedItems
    }
}

private struct DeletedItem {
    let id: String
    let parentID: String?
}

public final class HTTPRemoteAPIClient: RemoteAPIClient, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let jsonDecoder: JSONDecoder
    private let jsonEncoder: JSONEncoder

    public var requiresPostMutationSync: Bool {
        false
    }

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        self.jsonDecoder = JSONDecoder()
        self.jsonEncoder = JSONEncoder()
        self.jsonDecoder.dateDecodingStrategy = .iso8601
        self.jsonEncoder.dateEncodingStrategy = .iso8601
    }

    public func register(device: DeviceRegistration) async throws -> DevicePolicy {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/devices/register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonEncoder.encode(device)
        return try await executeJSON(request, as: DevicePolicy.self)
    }

    public func fetchChanges(cursor: String?) async throws -> RemoteChangeBatch {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/changes"), resolvingAgainstBaseURL: false)
        if let cursor {
            components?.queryItems = [URLQueryItem(name: "cursor", value: cursor)]
        }
        guard let url = components?.url else {
            throw CloudPlaceholderError.network("Invalid changes URL")
        }
        let request = URLRequest(url: url)
        return try await executeJSON(request, as: RemoteChangeBatch.self)
    }

    public func downloadContent(itemID: String, to destinationURL: URL) async throws -> SyncItem {
        let contentURL = baseURL.appendingPathComponent("api/items/\(itemID)/content")
        let metadataURL = baseURL.appendingPathComponent("api/items/\(itemID)")
        let (data, response) = try await session.data(from: contentURL)
        try validate(response: response, body: data)
        try data.write(to: destinationURL, options: .atomic)
        let metadataRequest = URLRequest(url: metadataURL)
        return try await executeJSON(metadataRequest, as: SyncItem.self)
    }

    public func uploadContent(descriptor: UploadDescriptor, fileURL: URL) async throws -> RemoteCommitResult {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/items/\(descriptor.itemID)/content"), resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "name", value: descriptor.fileName),
            URLQueryItem(name: "size", value: String(descriptor.fileSize))
        ]
        if let parentID = descriptor.parentID {
            queryItems.append(URLQueryItem(name: "parentId", value: parentID))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw CloudPlaceholderError.network("Invalid upload URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(descriptor.sha256, forHTTPHeaderField: "X-Content-SHA256")
        request.setValue(descriptor.baseContentVersion, forHTTPHeaderField: "X-Base-Content-Version")
        request.setValue(descriptor.baseMetadataVersion, forHTTPHeaderField: "X-Base-Metadata-Version")
        request.httpBody = try Data(contentsOf: fileURL)
        return try await executeJSON(request, as: RemoteCommitResult.self)
    }

    public func createDirectory(itemID: String, parentID: String?, name: String, baseMetadataVersion: String?) async throws -> RemoteCommitResult {
        guard let url = URL(string: "api/items/\(itemID)/directory", relativeTo: baseURL) else {
            throw CloudPlaceholderError.network("Invalid create directory URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonEncoder.encode(metadataPayload(name: name, parentID: parentID))
        return try await executeJSON(request, as: RemoteCommitResult.self)
    }

    public func updateMetadata(itemID: String, name: String, parentID: String?, baseMetadataVersion: String?) async throws -> RemoteCommitResult {
        let url = baseURL.appendingPathComponent("api/items/\(itemID)")
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonEncoder.encode(metadataPayload(name: name, parentID: parentID))
        return try await executeJSON(request, as: RemoteCommitResult.self)
    }

    public func deleteItem(itemID: String, baseMetadataVersion: String?) async throws -> String {
        let url = baseURL.appendingPathComponent("api/items/\(itemID)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let payload = try await executeJSON(request, as: [String: String].self)
        return payload["remoteCursor"] ?? String(Int64(Date().timeIntervalSince1970 * 1000))
    }

    private func executeJSON<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request)
        try validate(response: response, body: data)
        do {
            return try jsonDecoder.decode(T.self, from: data)
        } catch {
            throw CloudPlaceholderError.network("Failed to decode \(T.self): \(error)")
        }
    }

    private func validate(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CloudPlaceholderError.network("Missing HTTP response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let message = String(data: body, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            if http.statusCode == 409 {
                throw CloudPlaceholderError.versionConflict(message)
            }
            throw CloudPlaceholderError.network(message)
        }
    }

    private func metadataPayload(name: String, parentID: String?) -> [String: String] {
        var payload = ["name": name]
        if let parentID {
            payload["parentID"] = parentID
        }
        return payload
    }
}
