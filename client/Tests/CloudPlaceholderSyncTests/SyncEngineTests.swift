import CloudPlaceholderDomain
import CloudPlaceholderPersistence
import CloudPlaceholderSync
import Foundation
import Testing

private actor RemoteStub {
    var policy = DevicePolicy(offlineCacheLimitBytes: 1024 * 1024)
    var changeBatch = RemoteChangeBatch(items: [], deletedItemIDs: [], nextCursor: "1", hasMore: false)
    var items: [String: SyncItem] = [:]
    var uploadedDescriptors: [UploadDescriptor] = []

    func register(device: DeviceRegistration) -> DevicePolicy {
        policy
    }

    func changes(cursor: String?) -> RemoteChangeBatch {
        changeBatch
    }

    func item(id: String) -> SyncItem? {
        items[id]
    }

    func set(item: SyncItem) {
        items[item.id] = item
    }

    func set(changeBatch: RemoteChangeBatch) {
        self.changeBatch = changeBatch
    }

    func upload(descriptor: UploadDescriptor) throws -> RemoteCommitResult {
        uploadedDescriptors.append(descriptor)
        var resolvedItem = items[descriptor.itemID] ?? SyncItem(
                id: descriptor.itemID,
                parentID: "root",
                name: descriptor.fileName,
                kind: .file
            )
        if let currentVersion = resolvedItem.contentVersion, descriptor.baseContentVersion != nil, descriptor.baseContentVersion != currentVersion {
            throw CloudPlaceholderError.versionConflict(descriptor.itemID)
        }
        resolvedItem.name = descriptor.fileName
        resolvedItem.size = descriptor.fileSize
        resolvedItem.contentHash = descriptor.sha256
        resolvedItem.contentVersion = "v\(uploadedDescriptors.count + 1)"
        resolvedItem.metadataVersion = "m\(uploadedDescriptors.count + 1)"
        resolvedItem.state = .hydrated
        resolvedItem.hydrated = true
        resolvedItem.dirty = false
        resolvedItem.updatedAt = Date()
        items[resolvedItem.id] = resolvedItem
        return RemoteCommitResult(item: resolvedItem, remoteCursor: "\(uploadedDescriptors.count)")
    }
}

private struct RemoteAPIStub: RemoteAPIClient {
    let storage: RemoteStub

    var requiresPostMutationSync: Bool { false }

    func register(device: DeviceRegistration) async throws -> DevicePolicy {
        await storage.register(device: device)
    }

    func fetchChanges(cursor: String?) async throws -> RemoteChangeBatch {
        await storage.changes(cursor: cursor)
    }

    func downloadContent(itemID: String, to destinationURL: URL) async throws -> SyncItem {
        let content = "downloaded-\(itemID)"
        try content.write(to: destinationURL, atomically: true, encoding: .utf8)
        guard let item = await storage.item(id: itemID) else {
            throw CloudPlaceholderError.missingItem(itemID)
        }
        return item
    }

    func uploadContent(descriptor: UploadDescriptor, fileURL: URL) async throws -> RemoteCommitResult {
        try await storage.upload(descriptor: descriptor)
    }

    func createDirectory(itemID: String, parentID: String?, name: String, baseMetadataVersion: String?) async throws -> RemoteCommitResult {
        let item = SyncItem(
            id: itemID,
            parentID: parentID,
            name: name,
            kind: .directory,
            contentVersion: nil,
            metadataVersion: "m-dir",
            state: .hydrated,
            hydrated: true,
            dirty: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        await storage.set(item: item)
        return RemoteCommitResult(item: item, remoteCursor: "mkdir")
    }

    func updateMetadata(itemID: String, name: String, parentID: String?, baseMetadataVersion: String?) async throws -> RemoteCommitResult {
        guard var item = await storage.item(id: itemID) else {
            throw CloudPlaceholderError.missingItem(itemID)
        }
        item.name = name
        item.parentID = parentID
        item.metadataVersion = "m-update"
        item.updatedAt = Date()
        await storage.set(item: item)
        return RemoteCommitResult(item: item, remoteCursor: "meta")
    }

    func deleteItem(itemID: String, baseMetadataVersion: String?) async throws -> String {
        "delete"
    }
}

@Test
func syncEngineAppliesRemoteChangesAndUploadsLocalEdits() async throws {
    let testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    let store = try SQLiteMetadataStore(databaseURL: testDirectory.appendingPathComponent("state.sqlite"))
    let remoteStore = RemoteStub()

    let remoteItem = SyncItem(
        id: "plan.md",
        parentID: "root",
        name: "plan.md",
        kind: .file,
        size: 12,
        contentHash: "server",
        contentVersion: "v1",
        metadataVersion: "m1",
        state: .cloudOnly
    )
    await remoteStore.set(item: remoteItem)
    await remoteStore.set(changeBatch: RemoteChangeBatch(items: [remoteItem], deletedItemIDs: [], nextCursor: "1", hasMore: false))

    let engine = SyncEngine(domainID: "primary", store: store, remote: RemoteAPIStub(storage: remoteStore))
    try await engine.syncDown()

    let fetched = try #require(try store.item(id: "plan.md"))
    #expect(fetched.name == "plan.md")
    #expect(fetched.state == .cloudOnly)

    let localFile = testDirectory.appendingPathComponent("plan.md")
    try "locally edited".write(to: localFile, atomically: true, encoding: .utf8)
    _ = try engine.stageLocalFile(itemID: "plan.md", parentID: "root", fileURL: localFile)
    try await engine.flushPendingOperations()

    let uploaded = try #require(try store.item(id: "plan.md"))
    #expect(uploaded.dirty == false)
    #expect(uploaded.hydrated == true)

    let operations = try store.pendingOperations(in: [.done])
    #expect(operations.count == 1)
}

@Test
func syncEngineEvictsOnlyUnpinnedHydratedFiles() throws {
    let testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    let localFile = testDirectory.appendingPathComponent("cold.bin")
    try Data(repeating: 0x01, count: 64).write(to: localFile)

    let store = try SQLiteMetadataStore(databaseURL: testDirectory.appendingPathComponent("state.sqlite"))
    try store.upsert(
        item: SyncItem(
            id: "cold",
            parentID: "root",
            name: "cold.bin",
            kind: .file,
            size: 64,
            state: .hydrated,
            hydrated: true,
            pinned: false,
            dirty: false,
            localPath: localFile.path,
            lastUsedAt: Date(timeIntervalSince1970: 1)
        )
    )
    let remote = RemoteAPIStub(storage: RemoteStub())
    let engine = SyncEngine(domainID: "primary", store: store, remote: remote)

    let evicted = try engine.evictColdFiles(maximumCachedBytes: 0)
    #expect(evicted == ["cold"])
    #expect(FileManager.default.fileExists(atPath: localFile.path) == false)
}

@Test
func syncEngineDeleteDirectoryTombstonesDescendantsAndLogsProviderChanges() async throws {
    let testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    let store = try SQLiteMetadataStore(databaseURL: testDirectory.appendingPathComponent("state.sqlite"))

    try store.upsert(
        item: SyncItem(
            id: "folder",
            parentID: "root",
            name: "folder",
            kind: .directory,
            state: .hydrated,
            hydrated: true
        )
    )
    try store.upsert(
        item: SyncItem(
            id: "nested.txt",
            parentID: "folder",
            name: "nested.txt",
            kind: .file,
            state: .cloudOnly
        )
    )

    let engine = SyncEngine(domainID: "primary", store: store, remote: RemoteAPIStub(storage: RemoteStub()))
    _ = try engine.stageDeletion(itemID: "folder")
    try await engine.flushPendingOperations()

    let folder = try #require(try store.item(id: "folder"))
    let nested = try #require(try store.item(id: "nested.txt"))
    #expect(folder.deleted == true)
    #expect(nested.deleted == true)

    let changes = try store.providerChanges(domainID: "primary", after: 0, containerID: nil)
    let deletedIDs = changes.filter(\.deleted).map(\.itemID)
    #expect(Set(deletedIDs) == Set(["folder", "nested.txt"]))
}
