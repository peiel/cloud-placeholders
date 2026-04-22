import CloudPlaceholderDomain
import CloudPlaceholderSync
import FileProvider
import Foundation
import UniformTypeIdentifiers

@available(macOS 15.0, *)
public final class PlaceholderFileProviderItem: NSObject, NSFileProviderItem {
    public let model: SyncItem
    private let rootDisplayName: String

    public init(model: SyncItem, rootDisplayName: String) {
        self.model = model
        self.rootDisplayName = rootDisplayName
    }

    public var itemIdentifier: NSFileProviderItemIdentifier {
        if model.id == ProviderDomainController.rootItemID {
            return .rootContainer
        }
        return NSFileProviderItemIdentifier(model.id)
    }

    public var parentItemIdentifier: NSFileProviderItemIdentifier {
        if model.id == ProviderDomainController.rootItemID {
            return .rootContainer
        }
        if let parentID = model.parentID {
            return parentID == ProviderDomainController.rootItemID ? .rootContainer : NSFileProviderItemIdentifier(parentID)
        }
        return .rootContainer
    }

    public var filename: String {
        model.id == ProviderDomainController.rootItemID ? rootDisplayName : model.name
    }

    public var contentType: UTType {
        switch model.kind {
        case .directory:
            return .folder
        case .file:
            if let type = UTType(filenameExtension: (model.name as NSString).pathExtension), !model.name.isEmpty {
                return type
            }
            return .data
        }
    }

    public var capabilities: NSFileProviderItemCapabilities {
        switch model.kind {
        case .directory:
            return [.allowsReading, .allowsAddingSubItems, .allowsRenaming, .allowsReparenting, .allowsDeleting, .allowsTrashing]
        case .file:
            return [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting, .allowsTrashing]
        }
    }

    public var fileSystemFlags: NSFileProviderFileSystemFlags {
        [.userReadable, .userWritable]
    }

    public var documentSize: NSNumber? {
        model.kind == .file ? NSNumber(value: model.size) : nil
    }

    public var childItemCount: NSNumber? {
        model.kind == .directory ? 0 : nil
    }

    public var creationDate: Date? {
        model.createdAt
    }

    public var contentModificationDate: Date? {
        model.updatedAt
    }

    public var lastUsedDate: Date? {
        model.lastUsedAt
    }

    public var isUploaded: Bool {
        !model.dirty && model.state != .syncing
    }

    public var isUploading: Bool {
        model.state == .syncing
    }

    public var isDownloaded: Bool {
        model.hydrated
    }

    public var isDownloading: Bool {
        model.state == .syncing && !model.hydrated
    }

    public var isMostRecentVersionDownloaded: Bool {
        model.hydrated && model.state != .conflict
    }

    public var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(
            contentVersion: Data((model.contentVersion ?? "0").utf8),
            metadataVersion: Data((model.metadataVersion ?? "0").utf8)
        )
    }

    public var contentPolicy: NSFileProviderContentPolicy {
        model.pinned ? .downloadEagerlyAndKeepDownloaded : .downloadLazily
    }
}

@available(macOS 15.0, *)
public final class PlaceholderEnumerator: NSObject, NSFileProviderEnumerator {
    private let containerID: NSFileProviderItemIdentifier
    private let controller: ProviderDomainController
    private let prepare: @Sendable () async throws -> Void

    public init(
        containerID: NSFileProviderItemIdentifier,
        controller: ProviderDomainController,
        prepare: @escaping @Sendable () async throws -> Void
    ) {
        self.containerID = containerID
        self.controller = controller
        self.prepare = prepare
    }

    public func invalidate() {}

    public func enumerateItems(for observer: any NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let prepare = self.prepare
        let controller = self.controller
        let containerID = self.containerID
        let observerBox = UnsafeSendableBox(observer)
        Task<Void, Never> {
            do {
                try await prepare()
                let models = try controller.items(in: containerID)
                observerBox.value.didEnumerate(models.map { PlaceholderFileProviderItem(model: $0, rootDisplayName: controller.rootDisplayName) })
                observerBox.value.finishEnumerating(upTo: nil)
            } catch {
                observerBox.value.finishEnumeratingWithError(error as NSError)
            }
        }
    }

    public func enumerateChanges(for observer: any NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        let prepare = self.prepare
        let controller = self.controller
        let containerID = self.containerID
        let observerBox = UnsafeSendableBox(observer)
        Task<Void, Never> {
            do {
                try await prepare()
                let changeSet = try controller.changeSet(in: containerID, from: syncAnchor)
                if !changeSet.updated.isEmpty {
                    observerBox.value.didUpdate(changeSet.updated.map { PlaceholderFileProviderItem(model: $0, rootDisplayName: controller.rootDisplayName) })
                }
                if !changeSet.deleted.isEmpty {
                    observerBox.value.didDeleteItems(withIdentifiers: changeSet.deleted.map { NSFileProviderItemIdentifier($0) })
                }
                observerBox.value.finishEnumeratingChanges(upTo: controller.currentSyncAnchorData(), moreComing: false)
            } catch {
                observerBox.value.finishEnumeratingWithError(error as NSError)
            }
        }
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(controller.currentSyncAnchorData())
    }
}

private final class UnsafeSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

@available(macOS 15.0, *)
public final class ProviderDomainController: @unchecked Sendable {
    public static let rootItemID = "root"

    private let store: MetadataStore
    private let syncEngine: SyncEngine
    private let prepareEnumeration: @Sendable () async throws -> Void
    private let domainID: String
    public let rootDisplayName: String

    public init(
        store: MetadataStore,
        syncEngine: SyncEngine,
        rootDisplayName: String = "Enterprise Cloud Drive",
        domainID: String = "primary",
        prepareEnumeration: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.store = store
        self.syncEngine = syncEngine
        self.rootDisplayName = rootDisplayName
        self.domainID = domainID
        self.prepareEnumeration = prepareEnumeration
    }

    public func item(for identifier: NSFileProviderItemIdentifier) throws -> PlaceholderFileProviderItem {
        let internalID = mapProviderIdentifier(identifier)
        if internalID == Self.rootItemID {
            let root = SyncItem(
                id: Self.rootItemID,
                parentID: nil,
                name: rootDisplayName,
                kind: .directory,
                state: .hydrated,
                hydrated: true
            )
            return PlaceholderFileProviderItem(model: root, rootDisplayName: rootDisplayName)
        }
        guard let model = try store.item(id: internalID) else {
            throw CloudPlaceholderError.missingItem(internalID)
        }
        return PlaceholderFileProviderItem(model: model, rootDisplayName: rootDisplayName)
    }

    public func enumerator(for identifier: NSFileProviderItemIdentifier) -> PlaceholderEnumerator {
        PlaceholderEnumerator(containerID: identifier, controller: self, prepare: prepareEnumeration)
    }

    public func fetchContents(for identifier: NSFileProviderItemIdentifier, into cacheDirectory: URL) async throws -> (URL, PlaceholderFileProviderItem) {
        let internalID = mapProviderIdentifier(identifier)
        let materializedURL = try await syncEngine.materializeItem(itemID: internalID, cacheDirectory: cacheDirectory)
        guard let updated = try store.item(id: internalID) else {
            throw CloudPlaceholderError.missingItem(internalID)
        }
        return (materializedURL, PlaceholderFileProviderItem(model: updated, rootDisplayName: rootDisplayName))
    }

    fileprivate func items(in identifier: NSFileProviderItemIdentifier) throws -> [SyncItem] {
        let internalID = mapProviderIdentifier(identifier)
        let parentID = internalID == Self.rootItemID ? Self.rootItemID : internalID
        return try store.children(of: parentID)
    }

    fileprivate func currentSyncAnchorData() -> NSFileProviderSyncAnchor {
        let cursor = (try? store.syncState(domainID: domainID))?.workingSetCursor
            ?? String((try? store.latestProviderChangeSequence(domainID: domainID)) ?? 0)
        return NSFileProviderSyncAnchor(Data(cursor.utf8))
    }

    fileprivate func changeSet(in identifier: NSFileProviderItemIdentifier, from syncAnchor: NSFileProviderSyncAnchor) throws -> (updated: [SyncItem], deleted: [String]) {
        let cursor = String(decoding: syncAnchor.rawValue, as: UTF8.self)
        let sequence = Int64(cursor) ?? 0
        let containerID: String? = {
            switch identifier {
            case .workingSet:
                return nil
            case .rootContainer:
                return Self.rootItemID
            default:
                return identifier.rawValue
            }
        }()
        let changes = try store.providerChanges(domainID: domainID, after: sequence, containerID: containerID)
        var updated: [SyncItem] = []
        var deleted: [String] = []
        for change in changes {
            if change.deleted {
                deleted.append(change.itemID)
            } else if let item = try store.item(id: change.itemID) {
                updated.append(item)
            }
        }
        return (updated, deleted)
    }

    private func mapProviderIdentifier(_ identifier: NSFileProviderItemIdentifier) -> String {
        switch identifier {
        case .rootContainer, .workingSet:
            return Self.rootItemID
        default:
            return identifier.rawValue
        }
    }
}
