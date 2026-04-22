import CloudPlaceholderDomain
import CloudPlaceholderPersistence
import Foundation

public final class LocalDirectoryRemoteAPIClient: RemoteAPIClient, @unchecked Sendable {
    private let domainID: String
    private let store: SQLiteMetadataStore
    private let configurationStore: CloudDriveSharedConfigurationStore
    private let fileManager: FileManager

    public var requiresPostMutationSync: Bool {
        false
    }

    public init(
        domainID: String,
        store: SQLiteMetadataStore,
        configurationStore: CloudDriveSharedConfigurationStore = CloudDriveSharedConfigurationStore(),
        fileManager: FileManager = .default
    ) {
        self.domainID = domainID
        self.store = store
        self.configurationStore = configurationStore
        self.fileManager = fileManager
    }

    public func register(device: DeviceRegistration) async throws -> DevicePolicy {
        DevicePolicy()
    }

    public func fetchChanges(cursor: String?) async throws -> RemoteChangeBatch {
        let access = try resolvedRootAccess()
        let previousEntries = try store.sourceEntries(domainID: domainID)
        let scannedEntries = try scanEntries(rootURL: access.url, existingEntries: previousEntries)
        let previousByItemID = Dictionary(uniqueKeysWithValues: previousEntries.map { ($0.itemID, $0) })
        let scannedByItemID = Dictionary(uniqueKeysWithValues: scannedEntries.map { ($0.itemID, $0) })

        let items: [SyncItem]
        if cursor == nil || previousEntries.isEmpty {
            items = scannedEntries.map(makeSyncItem)
        } else {
            items = scannedEntries.compactMap { entry in
                guard previousByItemID[entry.itemID] != entry else {
                    return nil
                }
                return makeSyncItem(from: entry)
            }
        }

        let deletedItemIDs = previousEntries
            .filter { scannedByItemID[$0.itemID] == nil }
            .map(\.itemID)

        try store.replaceSourceEntries(domainID: domainID, entries: scannedEntries, removingItemIDs: deletedItemIDs)

        return RemoteChangeBatch(
            items: items,
            deletedItemIDs: deletedItemIDs,
            nextCursor: nextCursor(),
            hasMore: false
        )
    }

    public func downloadContent(itemID: String, to destinationURL: URL) async throws -> SyncItem {
        let access = try resolvedRootAccess()
        guard let entry = try store.sourceEntry(domainID: domainID, itemID: itemID) else {
            throw CloudPlaceholderError.missingItem(itemID)
        }
        let sourceURL = sourceURL(for: entry, rootURL: access.url)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw CloudPlaceholderError.localSourceUnavailable(sourceURL.path)
        }
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return makeSyncItem(from: entry)
    }

    public func uploadContent(descriptor: UploadDescriptor, fileURL: URL) async throws -> RemoteCommitResult {
        let access = try resolvedRootAccess()
        let existingEntry = try store.sourceEntry(domainID: domainID, itemID: descriptor.itemID)
        let parentResolution = try resolveParent(itemID: descriptor.parentID, rootURL: access.url)
        let destinationURL = parentResolution.url.appendingPathComponent(descriptor.fileName, isDirectory: false)
        let finalURL: URL
        if let existingEntry {
            let currentURL = sourceURL(for: existingEntry, rootURL: access.url)
            if currentURL.standardizedFileURL != destinationURL.standardizedFileURL {
                try moveOrReplaceItem(from: currentURL, to: destinationURL)
            }
            finalURL = destinationURL
        } else {
            finalURL = destinationURL
        }
        try writeReplacingItem(from: fileURL, to: finalURL)
        let entry = try upsertSourceEntry(
            for: finalURL,
            itemID: descriptor.itemID,
            parentSourceID: parentResolution.parentSourceID,
            parentItemID: parentResolution.parentItemID
        )
        return RemoteCommitResult(item: makeSyncItem(from: entry), remoteCursor: nextCursor())
    }

    public func createDirectory(itemID: String, parentID: String?, name: String, baseMetadataVersion: String?) async throws -> RemoteCommitResult {
        let access = try resolvedRootAccess()
        let parentResolution = try resolveParent(itemID: parentID, rootURL: access.url)
        let directoryURL = parentResolution.url.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let entry = try upsertSourceEntry(
            for: directoryURL,
            itemID: itemID,
            parentSourceID: parentResolution.parentSourceID,
            parentItemID: parentResolution.parentItemID
        )
        return RemoteCommitResult(item: makeSyncItem(from: entry), remoteCursor: nextCursor())
    }

    public func updateMetadata(itemID: String, name: String, parentID: String?, baseMetadataVersion: String?) async throws -> RemoteCommitResult {
        let access = try resolvedRootAccess()
        guard let existingEntry = try store.sourceEntry(domainID: domainID, itemID: itemID) else {
            throw CloudPlaceholderError.missingItem(itemID)
        }
        let source = sourceURL(for: existingEntry, rootURL: access.url)
        let parentResolution = try resolveParent(itemID: parentID, rootURL: access.url)
        let destination = parentResolution.url.appendingPathComponent(name, isDirectory: existingEntry.kind == .directory)
        if source.standardizedFileURL != destination.standardizedFileURL {
            try moveOrReplaceItem(from: source, to: destination)
        }
        let entry = try upsertSourceEntry(
            for: destination,
            itemID: itemID,
            parentSourceID: parentResolution.parentSourceID,
            parentItemID: parentResolution.parentItemID,
            existingEntry: existingEntry
        )
        return RemoteCommitResult(item: makeSyncItem(from: entry), remoteCursor: nextCursor())
    }

    public func deleteItem(itemID: String, baseMetadataVersion: String?) async throws -> String {
        let access = try resolvedRootAccess()
        guard let entry = try store.sourceEntry(domainID: domainID, itemID: itemID) else {
            throw CloudPlaceholderError.missingItem(itemID)
        }
        let url = sourceURL(for: entry, rootURL: access.url)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        let removingItemIDs = try subtreeItemIDs(for: entry)
        try store.replaceSourceEntries(domainID: domainID, entries: [], removingItemIDs: removingItemIDs)
        return nextCursor()
    }

    private func resolvedRootAccess() throws -> SecurityScopedResourceAccess {
        let configuration = configurationStore.loadBackendConfiguration()
        guard let bookmarkData = configuration.sourceBookmarkData else {
            throw CloudPlaceholderError.localSourceUnavailable("No local directory has been selected")
        }
        return try SecurityScopedResourceAccess(bookmarkData: bookmarkData)
    }

    private func scanEntries(rootURL: URL, existingEntries: [SourceEntry]) throws -> [SourceEntry] {
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .contentModificationDateKey,
            .fileSizeKey,
            .fileResourceIdentifierKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else {
            return []
        }

        let existingBySourceID = Dictionary(uniqueKeysWithValues: existingEntries.map { ($0.sourceID, $0) })
        let existingByRelativePath = Dictionary(uniqueKeysWithValues: existingEntries.map { ($0.relativePath, $0) })
        var rawEntries: [ScannedEntry] = []

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: resourceKeys)
            let relativePath = relativePath(for: url, rootURL: rootURL)
            guard !relativePath.isEmpty else {
                continue
            }
            if IgnoredSystemFileMatcher.shouldIgnore(filename: url.lastPathComponent) {
                continue
            }
            let sourceID = makeSourceID(values: values, relativePath: relativePath, existingByRelativePath: existingByRelativePath)
            rawEntries.append(
                ScannedEntry(
                    sourceID: sourceID,
                    parentSourceID: nil,
                    relativePath: relativePath,
                    name: url.lastPathComponent,
                    kind: values.isDirectory == true ? .directory : .file,
                    size: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
                )
            )
        }

        let sorted = rawEntries.sorted { lhs, rhs in
            let leftDepth = lhs.relativePath.split(separator: "/").count
            let rightDepth = rhs.relativePath.split(separator: "/").count
            if leftDepth == rightDepth {
                return lhs.relativePath < rhs.relativePath
            }
            return leftDepth < rightDepth
        }

        var sourceToItemID: [String: String] = [:]
        let sourceIDByRelativePath = Dictionary(uniqueKeysWithValues: sorted.map { ($0.relativePath, $0.sourceID) })
        for entry in sorted {
            let existing = existingBySourceID[entry.sourceID] ?? existingByRelativePath[entry.relativePath]
            sourceToItemID[entry.sourceID] = existing?.itemID ?? UUID().uuidString
        }

        return sorted.map { entry in
            let existing = existingBySourceID[entry.sourceID] ?? existingByRelativePath[entry.relativePath]
            let itemID = sourceToItemID[entry.sourceID] ?? existing?.itemID ?? UUID().uuidString
            let parentSourceID = parentRelativePath(for: entry.relativePath).flatMap { sourceIDByRelativePath[$0] }
            let parentItemID = parentSourceID.flatMap { sourceToItemID[$0] } ?? CloudDriveRuntime.rootItemID
            let versions = makeVersions(for: entry)
            return SourceEntry(
                sourceID: entry.sourceID,
                domainID: domainID,
                itemID: itemID,
                parentSourceID: parentSourceID,
                parentItemID: parentItemID,
                relativePath: entry.relativePath,
                name: entry.name,
                kind: entry.kind,
                size: entry.size,
                contentVersion: versions.contentVersion,
                metadataVersion: versions.metadataVersion,
                remoteModifiedAt: entry.modifiedAt,
                updatedAt: entry.modifiedAt
            )
        }
    }

    private func makeSourceID(
        values: URLResourceValues,
        relativePath: String,
        existingByRelativePath: [String: SourceEntry]
    ) -> String {
        if let identifier = values.fileResourceIdentifier {
            return "file-resource:\(String(describing: identifier))"
        }
        if let existing = existingByRelativePath[relativePath] {
            return existing.sourceID
        }
        return "generated:\(UUID().uuidString)"
    }

    private func upsertSourceEntry(
        for url: URL,
        itemID: String,
        parentSourceID: String?,
        parentItemID: String?,
        existingEntry: SourceEntry? = nil
    ) throws -> SourceEntry {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .contentModificationDateKey,
            .fileSizeKey,
            .fileResourceIdentifierKey
        ])
        let access = try resolvedRootAccess()
        let relativePath = relativePath(for: url, rootURL: access.url)
        let sourceID = existingEntry?.sourceID ?? makeSourceID(values: values, relativePath: relativePath, existingByRelativePath: [:])
        let scanned = ScannedEntry(
            sourceID: sourceID,
            parentSourceID: parentSourceID,
            relativePath: relativePath,
            name: url.lastPathComponent,
            kind: values.isDirectory == true ? .directory : .file,
            size: Int64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate ?? Date()
        )
        let versions = makeVersions(for: scanned)
        let entry = SourceEntry(
            sourceID: sourceID,
            domainID: domainID,
            itemID: itemID,
            parentSourceID: parentSourceID,
            parentItemID: parentItemID ?? CloudDriveRuntime.rootItemID,
            relativePath: relativePath,
            name: scanned.name,
            kind: scanned.kind,
            size: scanned.size,
            contentVersion: versions.contentVersion,
            metadataVersion: versions.metadataVersion,
            remoteModifiedAt: scanned.modifiedAt,
            updatedAt: scanned.modifiedAt
        )
        try store.replaceSourceEntries(domainID: domainID, entries: [entry], removingItemIDs: [])
        return entry
    }

    private func resolveParent(itemID: String?, rootURL: URL) throws -> ParentResolution {
        guard let itemID, itemID != CloudDriveRuntime.rootItemID else {
            return ParentResolution(url: rootURL, parentSourceID: nil, parentItemID: CloudDriveRuntime.rootItemID)
        }
        guard let entry = try store.sourceEntry(domainID: domainID, itemID: itemID) else {
            throw CloudPlaceholderError.missingItem(itemID)
        }
        return ParentResolution(
            url: sourceURL(for: entry, rootURL: rootURL),
            parentSourceID: entry.sourceID,
            parentItemID: entry.itemID
        )
    }

    private func sourceURL(for entry: SourceEntry, rootURL: URL) -> URL {
        rootURL.appendingPathComponent(entry.relativePath, isDirectory: entry.kind == .directory)
    }

    private func subtreeItemIDs(for entry: SourceEntry) throws -> [String] {
        let prefix = entry.relativePath + "/"
        return try store.sourceEntries(domainID: domainID)
            .filter { candidate in
                candidate.itemID == entry.itemID
                    || candidate.relativePath.hasPrefix(prefix)
            }
            .map(\.itemID)
    }

    private func makeSyncItem(from entry: SourceEntry) -> SyncItem {
        SyncItem(
            id: entry.itemID,
            parentID: entry.parentItemID,
            name: entry.name,
            kind: entry.kind,
            size: entry.size,
            contentVersion: entry.contentVersion,
            metadataVersion: entry.metadataVersion,
            remoteModifiedAt: entry.remoteModifiedAt,
            state: entry.kind == .directory ? .hydrated : .cloudOnly,
            hydrated: entry.kind == .directory,
            createdAt: entry.updatedAt,
            updatedAt: entry.updatedAt
        )
    }

    private func writeReplacingItem(from sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tempURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        if fileManager.fileExists(atPath: tempURL.path) {
            try fileManager.removeItem(at: tempURL)
        }
        try fileManager.copyItem(at: sourceURL, to: tempURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: tempURL, to: destinationURL)
    }

    private func moveOrReplaceItem(from sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            throw CloudPlaceholderError.invalidState("Destination already exists at \(destinationURL.path)")
        }
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    private func relativePath(for url: URL, rootURL: URL) -> String {
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let path = url.path
        if path.hasPrefix(rootPath) {
            return String(path.dropFirst(rootPath.count))
        }
        return path
    }

    private func parentRelativePath(for relativePath: String) -> String? {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent.isEmpty || parent == "." ? nil : parent
    }

    private func makeVersions(for entry: ScannedEntry) -> (contentVersion: String?, metadataVersion: String) {
        let modified = Int64(entry.modifiedAt.timeIntervalSince1970.rounded())
        let contentVersion = entry.kind == .file ? "content-\(entry.size)-\(modified)" : nil
        let metadataVersion = "meta-\(entry.relativePath)-\(entry.kind.rawValue)-\(entry.size)-\(modified)"
        return (contentVersion, metadataVersion)
    }

    private func nextCursor() -> String {
        String(Int64(Date().timeIntervalSince1970 * 1000))
    }
}

private struct ParentResolution {
    let url: URL
    let parentSourceID: String?
    let parentItemID: String?
}

private struct ScannedEntry {
    let sourceID: String
    let parentSourceID: String?
    let relativePath: String
    let name: String
    let kind: ItemKind
    let size: Int64
    let modifiedAt: Date
}
