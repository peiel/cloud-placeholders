import CloudPlaceholderDomain
import CloudPlaceholderPersistence
import Foundation
import Testing

@Test
func sqliteStorePersistsItemsAndCacheState() throws {
    let testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    let databaseURL = testDirectory.appendingPathComponent("state.sqlite")
    let store = try SQLiteMetadataStore(databaseURL: databaseURL)

    let item = SyncItem(
        id: "spec.docx",
        parentID: "root",
        name: "spec.docx",
        kind: .file,
        size: 256,
        contentHash: "abc",
        contentVersion: "v1",
        metadataVersion: "m1",
        state: .hydrated,
        hydrated: true,
        pinned: false,
        dirty: false,
        localPath: "/tmp/spec.docx"
    )

    try store.upsert(item: item)
    let fetched = try #require(try store.item(id: "spec.docx"))
    #expect(fetched.name == "spec.docx")
    #expect(fetched.hydrated == true)

    let totalCached = try store.totalCachedBytes()
    #expect(totalCached == 256)

    let candidates = try store.evictionCandidates(limit: 10)
    #expect(candidates.map(\.id) == ["spec.docx"])
}

@Test
func sqliteStoreTracksPendingOperationsAndSyncState() throws {
    let testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    let databaseURL = testDirectory.appendingPathComponent("state.sqlite")
    let store = try SQLiteMetadataStore(databaseURL: databaseURL)

    let operation = PendingOperation(
        itemID: "draft.txt",
        type: .modify,
        baseContentVersion: "v1",
        baseMetadataVersion: "m1",
        payloadJSON: #"{"filePath":"/tmp/draft.txt"}"#
    )
    try store.enqueue(operation)
    try store.save(syncState: SyncCursorState(domainID: "primary", remoteCursor: "42"))

    let queued = try store.pendingOperations(in: [.queued])
    #expect(queued.count == 1)
    #expect(queued.first?.itemID == "draft.txt")

    let cursor = try #require(try store.syncState(domainID: "primary"))
    #expect(cursor.remoteCursor == "42")
}

@Test
func sqliteStorePersistsProviderChanges() throws {
    let testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    let databaseURL = testDirectory.appendingPathComponent("state.sqlite")
    let store = try SQLiteMetadataStore(databaseURL: databaseURL)

    let sequence = try store.appendProviderChanges(
        domainID: "primary",
        changes: [
            ProviderChange(
                domainID: "primary",
                itemID: "spec.docx",
                parentItemID: "root",
                changeType: .update,
                deleted: false
            )
        ]
    )
    #expect(sequence > 0)

    let changes = try store.providerChanges(domainID: "primary", after: 0, containerID: nil)
    #expect(changes.count == 1)
    #expect(changes.first?.itemID == "spec.docx")
}
