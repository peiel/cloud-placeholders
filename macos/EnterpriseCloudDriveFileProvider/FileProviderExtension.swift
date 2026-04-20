import CloudPlaceholderDomain
import CloudPlaceholderFileProviderKit
import CloudPlaceholderPersistence
import CloudPlaceholderSync
import FileProvider
import Foundation

private enum CloudDriveSharedConfiguration {
    static let appGroupID = "group.com.peiel.enterprisecloud.drive"
    static let mockServerURLKey = "MockServerURL"
    static let defaultMockServerURL = "http://127.0.0.1:8787"

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }
}

@objc(FileProviderExtension)
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, @unchecked Sendable {
    private let domain: NSFileProviderDomain
    private let store: SQLiteMetadataStore
    private let syncEngine: SyncEngine
    private let controller: ProviderDomainController
    private let stagingDirectory: URL
    private let cacheDirectory: URL

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        let runtime = ExtensionRuntime.bootstrap(domainIdentifier: domain.identifier.rawValue)
        self.store = runtime.store
        self.syncEngine = runtime.syncEngine
        self.controller = runtime.controller
        self.stagingDirectory = runtime.stagingDirectory
        self.cacheDirectory = runtime.cacheDirectory
        super.init()
    }

    func invalidate() {}

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> any NSFileProviderEnumerator {
        controller.enumerator(for: containerItemIdentifier)
    }

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping ((any NSFileProviderItem)?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        do {
            completionHandler(try controller.item(for: identifier), nil)
            progress.completedUnitCount = 1
        } catch {
            completionHandler(nil, error)
        }
        return progress
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, (any NSFileProviderItem)?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let controller = self.controller
        let cacheDirectory = self.cacheDirectory
        let completion = UnsafeSendableBox(completionHandler)
        Task {
            do {
                let (url, item) = try await controller.fetchContents(for: itemIdentifier, into: cacheDirectory)
                completion.value(url, item, nil)
                progress.completedUnitCount = 1
            } catch {
                completion.value(nil, nil, error)
            }
        }
        return progress
    }

    func createItem(
        basedOn itemTemplate: any NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping ((any NSFileProviderItem)?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let store = self.store
        let syncEngine = self.syncEngine
        let controller = self.controller
        let stagingDirectory = self.stagingDirectory
        let completion = UnsafeSendableBox(completionHandler)
        let snapshot = TemplateSnapshot(item: itemTemplate)
        Task {
            do {
                let item = try await Self.stageLocalChange(
                    template: snapshot,
                    contents: url,
                    store: store,
                    syncEngine: syncEngine,
                    controller: controller,
                    stagingDirectory: stagingDirectory
                )
                completion.value(item, [], false, nil)
                progress.completedUnitCount = 1
            } catch {
                completion.value(nil, [], false, error)
            }
        }
        return progress
    }

    func modifyItem(
        _ item: any NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping ((any NSFileProviderItem)?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let store = self.store
        let syncEngine = self.syncEngine
        let controller = self.controller
        let stagingDirectory = self.stagingDirectory
        let completion = UnsafeSendableBox(completionHandler)
        let snapshot = TemplateSnapshot(item: item)
        Task {
            do {
                let item = try await Self.stageLocalChange(
                    template: snapshot,
                    contents: newContents,
                    store: store,
                    syncEngine: syncEngine,
                    controller: controller,
                    stagingDirectory: stagingDirectory
                )
                completion.value(item, [], false, nil)
                progress.completedUnitCount = 1
            } catch {
                completion.value(nil, [], false, error)
            }
        }
        return progress
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        do {
            try store.tombstone(itemID: Self.mapProviderIdentifier(identifier), updatedAt: Date())
            completionHandler(nil)
            progress.completedUnitCount = 1
        } catch {
            completionHandler(error)
        }
        return progress
    }

    private static func stageLocalChange(
        template: TemplateSnapshot,
        contents url: URL?,
        store: SQLiteMetadataStore,
        syncEngine: SyncEngine,
        controller: ProviderDomainController,
        stagingDirectory: URL
    ) async throws -> any NSFileProviderItem {
        let itemID = template.itemID
        let parentID = template.parentID
        if let url {
            let clonedURL = try cloneSystemOwnedFile(url, itemID: itemID, filename: template.filename, stagingDirectory: stagingDirectory)
            _ = try syncEngine.stageLocalFile(itemID: itemID, parentID: parentID, fileURL: clonedURL)
            try await syncEngine.flushPendingUploads()
        } else {
            let now = Date()
            try store.upsert(
                item: SyncItem(
                    id: itemID,
                    parentID: parentID,
                    name: template.filename,
                    kind: .directory,
                    state: .dirty,
                    hydrated: true,
                    dirty: true,
                    createdAt: now,
                    updatedAt: now
                )
            )
        }
        return try controller.item(for: template.providerIdentifier)
    }

    private static func cloneSystemOwnedFile(_ url: URL, itemID: String, filename: String, stagingDirectory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let destination = stagingDirectory.appendingPathComponent("\(itemID)-\(filename)")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    static func mapProviderIdentifier(_ identifier: NSFileProviderItemIdentifier) -> String {
        switch identifier {
        case .rootContainer, .workingSet:
            return ProviderDomainController.rootItemID
        default:
            return identifier.rawValue
        }
    }
}

private enum ExtensionRuntime {
    static func bootstrap(domainIdentifier: String) -> (
        store: SQLiteMetadataStore,
        syncEngine: SyncEngine,
        controller: ProviderDomainController,
        stagingDirectory: URL,
        cacheDirectory: URL
    ) {
        do {
            let root = try runtimeRoot(domainIdentifier: domainIdentifier)
            let databaseURL = root.appendingPathComponent("state.sqlite")
            let cacheDirectory = root.appendingPathComponent("cache", isDirectory: true)
            let stagingDirectory = root.appendingPathComponent("staging", isDirectory: true)
            let store = try SQLiteMetadataStore(databaseURL: databaseURL)
            try seedRootIfNeeded(store: store)
            let remoteURL = URL(
                string: CloudDriveSharedConfiguration.sharedDefaults.string(
                    forKey: CloudDriveSharedConfiguration.mockServerURLKey
                ) ?? CloudDriveSharedConfiguration.defaultMockServerURL
            )!
            let syncEngine = SyncEngine(
                domainID: domainIdentifier,
                store: store,
                remote: HTTPRemoteAPIClient(baseURL: remoteURL)
            )
            let controller = ProviderDomainController(store: store, syncEngine: syncEngine)
            return (store, syncEngine, controller, stagingDirectory, cacheDirectory)
        } catch {
            fatalError("Unable to bootstrap File Provider runtime: \(error)")
        }
    }

    private static func runtimeRoot(domainIdentifier: String) throws -> URL {
        let fileManager = FileManager.default
        let base = (
            fileManager.containerURL(forSecurityApplicationGroupIdentifier: CloudDriveSharedConfiguration.appGroupID)
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        )
            .appendingPathComponent("EnterpriseCloudDriveShared", isDirectory: true)
            .appendingPathComponent(domainIdentifier, isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func seedRootIfNeeded(store: SQLiteMetadataStore) throws {
        guard try store.item(id: ProviderDomainController.rootItemID) == nil else {
            return
        }
        try store.upsert(
            item: SyncItem(
                id: ProviderDomainController.rootItemID,
                parentID: nil,
                name: "Enterprise Cloud Drive",
                kind: .directory,
                state: .hydrated,
                hydrated: true
            )
        )
    }
}

private final class UnsafeSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private struct TemplateSnapshot: Sendable {
    let providerIdentifier: NSFileProviderItemIdentifier
    let itemID: String
    let parentID: String
    let filename: String

    init(item: any NSFileProviderItem) {
        self.providerIdentifier = item.itemIdentifier
        self.itemID = FileProviderExtension.mapProviderIdentifier(item.itemIdentifier)
        self.parentID = FileProviderExtension.mapProviderIdentifier(item.parentItemIdentifier)
        self.filename = item.filename
    }
}
