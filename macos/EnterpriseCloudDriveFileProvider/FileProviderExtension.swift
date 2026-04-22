import CloudPlaceholderDomain
import CloudPlaceholderFileProviderKit
import CloudPlaceholderPersistence
import CloudPlaceholderSync
import FileProvider
import Foundation

@objc(FileProviderExtension)
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, @unchecked Sendable {
    private let domain: NSFileProviderDomain
    private let store: SQLiteMetadataStore
    private let syncEngine: SyncEngine
    private let controller: ProviderDomainController
    private let bootstrapCoordinator: SyncBootstrapCoordinator
    private let stagingDirectory: URL
    private let cacheDirectory: URL

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        let runtime: CloudDriveRuntimeContext
        do {
            runtime = try CloudDriveRuntime.bootstrap(domainIdentifier: domain.identifier.rawValue)
        } catch {
            fatalError("Unable to bootstrap File Provider runtime: \(error)")
        }
        self.store = runtime.store
        self.syncEngine = runtime.syncEngine
        self.stagingDirectory = runtime.stagingDirectory
        self.cacheDirectory = runtime.cacheDirectory
        self.bootstrapCoordinator = SyncBootstrapCoordinator(
            domainID: domain.identifier.rawValue,
            store: runtime.store,
            syncEngine: runtime.syncEngine
        )
        self.controller = ProviderDomainController(
            store: runtime.store,
            syncEngine: runtime.syncEngine,
            rootDisplayName: runtime.configuration.domainDisplayName,
            domainID: domain.identifier.rawValue,
            prepareEnumeration: { [bootstrapCoordinator] in
                try await bootstrapCoordinator.ensureInitialSync()
            }
        )
        super.init()
        Task {
            try? await bootstrapCoordinator.ensureInitialSync()
        }
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
        let controller = self.controller
        let coordinator = self.bootstrapCoordinator
        let completion = UnsafeSendableBox(completionHandler)
        Task {
            do {
                try await coordinator.ensureInitialSync()
                completion.value(try controller.item(for: identifier), nil)
                progress.completedUnitCount = 1
            } catch {
                completion.value(nil, error)
            }
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
        let coordinator = self.bootstrapCoordinator
        let completion = UnsafeSendableBox(completionHandler)
        Task {
            do {
                try await coordinator.ensureInitialSync()
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
        let domainIdentifier = self.domain.identifier.rawValue
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
                    stagingDirectory: stagingDirectory,
                    domainIdentifier: domainIdentifier,
                    previousParentID: snapshot.parentID
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
        let domainIdentifier = self.domain.identifier.rawValue
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
                    stagingDirectory: stagingDirectory,
                    domainIdentifier: domainIdentifier,
                    previousParentID: snapshot.parentID
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
        let syncEngine = self.syncEngine
        let completion = UnsafeSendableBox(completionHandler)
        let itemID = Self.mapProviderIdentifier(identifier)
        let previousParentID = (try? store.item(id: itemID))?.parentID ?? CloudDriveRuntime.rootItemID
        let domainIdentifier = self.domain.identifier.rawValue
        Task {
            do {
                _ = try syncEngine.stageDeletion(itemID: itemID)
                try await syncEngine.flushPendingOperations()
                await FileProviderDomainSignaler.signal(
                    domainIdentifier: domainIdentifier,
                    itemIdentifiers: Set([itemID, previousParentID, CloudDriveRuntime.rootItemID])
                )
                completion.value(nil)
                progress.completedUnitCount = 1
            } catch {
                completion.value(error)
            }
        }
        return progress
    }

    private static func stageLocalChange(
        template: TemplateSnapshot,
        contents url: URL?,
        store: SQLiteMetadataStore,
        syncEngine: SyncEngine,
        controller: ProviderDomainController,
        stagingDirectory: URL,
        domainIdentifier: String,
        previousParentID: String
    ) async throws -> any NSFileProviderItem {
        let itemID = template.itemID
        let parentID = template.parentID
        if let url {
            let clonedURL = try cloneSystemOwnedFile(url, itemID: itemID, filename: template.filename, stagingDirectory: stagingDirectory)
            _ = try syncEngine.stageLocalFile(itemID: itemID, parentID: parentID, fileURL: clonedURL)
        } else if try store.item(id: itemID) == nil {
            _ = try syncEngine.stageDirectoryCreation(itemID: itemID, parentID: parentID, name: template.filename)
        } else {
            _ = try syncEngine.stageMetadataChange(itemID: itemID, parentID: parentID, name: template.filename)
        }
        try await syncEngine.flushPendingOperations()
        await FileProviderDomainSignaler.signal(
            domainIdentifier: domainIdentifier,
            itemIdentifiers: Set([itemID, parentID, previousParentID, CloudDriveRuntime.rootItemID])
        )
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
