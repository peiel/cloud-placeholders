import CloudPlaceholderDomain
import CloudPlaceholderPersistence
import CryptoKit
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct UploadPayload: Codable, Equatable, Sendable {
    public var filePath: String
    public var fileName: String
    public var fileSize: Int64
    public var sha256: String
}

public final class SyncEngine: @unchecked Sendable {
    private let store: MetadataStore
    private let remote: RemoteAPIClient
    private let fileManager: FileManager
    private let domainID: String

    public init(
        domainID: String,
        store: MetadataStore,
        remote: RemoteAPIClient,
        fileManager: FileManager = .default
    ) {
        self.domainID = domainID
        self.store = store
        self.remote = remote
        self.fileManager = fileManager
    }

    @discardableResult
    public func register(device: DeviceRegistration) async throws -> DevicePolicy {
        try await remote.register(device: device)
    }

    public func syncDown() async throws {
        var cursorState = try store.syncState(domainID: domainID) ?? SyncCursorState(domainID: domainID)
        var nextCursor = cursorState.remoteCursor
        repeat {
            let batch = try await remote.fetchChanges(cursor: nextCursor)
            for item in batch.items {
                try store.upsert(item: item)
            }
            for deletedID in batch.deletedItemIDs {
                try store.tombstone(itemID: deletedID, updatedAt: Date())
            }
            nextCursor = batch.nextCursor
            cursorState.remoteCursor = batch.nextCursor
            cursorState.lastFullSyncAt = Date()
            try store.save(syncState: cursorState)
            if !batch.hasMore {
                break
            }
        } while true
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

        let payload = UploadPayload(
            filePath: fileURL.path,
            fileName: fileURL.lastPathComponent,
            fileSize: fileSize,
            sha256: sha256
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

    public func flushPendingUploads() async throws {
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
                    UploadPayload.self,
                    from: Data(operation.payloadJSON.utf8)
                )
                let fileURL = URL(fileURLWithPath: payload.filePath)
                let descriptor = UploadDescriptor(
                    operationID: operation.id,
                    itemID: operation.itemID,
                    fileName: payload.fileName,
                    fileSize: payload.fileSize,
                    sha256: payload.sha256,
                    baseContentVersion: operation.baseContentVersion,
                    baseMetadataVersion: operation.baseMetadataVersion
                )
                let result = try await remote.uploadContent(descriptor: descriptor, fileURL: fileURL)
                var item = result.item
                item.localPath = payload.filePath
                item.hydrated = true
                item.dirty = false
                item.state = .hydrated
                item.lastUsedAt = Date()
                item.updatedAt = Date()
                try store.upsert(item: item)
                try store.markHydrated(
                    itemID: item.id,
                    localPath: payload.filePath,
                    size: payload.fileSize,
                    checksum: payload.sha256,
                    lastUsedAt: Date()
                )
                var cursorState = try store.syncState(domainID: domainID) ?? SyncCursorState(domainID: domainID)
                cursorState.remoteCursor = result.remoteCursor
                cursorState.lastPushAt = Date()
                try store.save(syncState: cursorState)
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
}

public final class HTTPRemoteAPIClient: RemoteAPIClient, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let jsonDecoder: JSONDecoder
    private let jsonEncoder: JSONEncoder

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
        components?.queryItems = [
            URLQueryItem(name: "name", value: descriptor.fileName),
            URLQueryItem(name: "size", value: String(descriptor.fileSize))
        ]
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
}
