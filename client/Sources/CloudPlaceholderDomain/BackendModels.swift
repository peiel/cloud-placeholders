import Foundation

public enum BackendKind: String, Codable, CaseIterable, Sendable {
    case mockServer
    case localDirectory
}

public struct BackendConfiguration: Codable, Equatable, Sendable {
    public var backendKind: BackendKind
    public var mockServerURL: String?
    public var sourceBookmarkData: Data?
    public var sourceDisplayName: String?
    public var domainDisplayName: String

    public init(
        backendKind: BackendKind = .mockServer,
        mockServerURL: String? = nil,
        sourceBookmarkData: Data? = nil,
        sourceDisplayName: String? = nil,
        domainDisplayName: String = "Enterprise Cloud Drive"
    ) {
        self.backendKind = backendKind
        self.mockServerURL = mockServerURL
        self.sourceBookmarkData = sourceBookmarkData
        self.sourceDisplayName = sourceDisplayName
        self.domainDisplayName = domainDisplayName
    }
}

public struct SourceEntry: Codable, Equatable, Identifiable, Sendable {
    public let sourceID: String
    public var domainID: String
    public var itemID: String
    public var parentSourceID: String?
    public var parentItemID: String?
    public var relativePath: String
    public var name: String
    public var kind: ItemKind
    public var size: Int64
    public var contentVersion: String?
    public var metadataVersion: String?
    public var remoteModifiedAt: Date?
    public var updatedAt: Date

    public var id: String {
        sourceID
    }

    public init(
        sourceID: String,
        domainID: String,
        itemID: String,
        parentSourceID: String?,
        parentItemID: String?,
        relativePath: String,
        name: String,
        kind: ItemKind,
        size: Int64,
        contentVersion: String? = nil,
        metadataVersion: String? = nil,
        remoteModifiedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.sourceID = sourceID
        self.domainID = domainID
        self.itemID = itemID
        self.parentSourceID = parentSourceID
        self.parentItemID = parentItemID
        self.relativePath = relativePath
        self.name = name
        self.kind = kind
        self.size = size
        self.contentVersion = contentVersion
        self.metadataVersion = metadataVersion
        self.remoteModifiedAt = remoteModifiedAt
        self.updatedAt = updatedAt
    }
}

public enum ProviderChangeType: String, Codable, CaseIterable, Sendable {
    case update
    case delete
}

public struct ProviderChange: Codable, Equatable, Identifiable, Sendable {
    public let sequence: Int64
    public var domainID: String
    public var itemID: String
    public var parentItemID: String?
    public var previousParentItemID: String?
    public var changeType: ProviderChangeType
    public var deleted: Bool
    public var changedAt: Date

    public var id: Int64 {
        sequence
    }

    public init(
        sequence: Int64 = 0,
        domainID: String,
        itemID: String,
        parentItemID: String?,
        previousParentItemID: String? = nil,
        changeType: ProviderChangeType,
        deleted: Bool,
        changedAt: Date = Date()
    ) {
        self.sequence = sequence
        self.domainID = domainID
        self.itemID = itemID
        self.parentItemID = parentItemID
        self.previousParentItemID = previousParentItemID
        self.changeType = changeType
        self.deleted = deleted
        self.changedAt = changedAt
    }
}
