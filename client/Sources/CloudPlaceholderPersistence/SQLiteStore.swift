import CloudPlaceholderDomain
import Foundation

public final class SQLiteMetadataStore: MetadataStore, @unchecked Sendable {
    private let queue = DispatchQueue(label: "CloudPlaceholder.SQLiteMetadataStore")
    private let connection: SQLiteConnection

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.connection = try SQLiteConnection(path: databaseURL.path)
        try bootstrap()
    }

    public func bootstrap() throws {
        try queue.sync {
            try connection.execute(CloudPlaceholderSchema.sql)
        }
    }

    public func upsert(item: SyncItem) throws {
        try queue.sync {
            try connection.withStatement(
                """
                INSERT INTO items (
                  item_id, parent_id, name, is_dir, size, content_hash, content_version, metadata_version,
                  remote_mtime, deleted, state, hydrated, pinned, dirty, local_path, last_used_at, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(item_id) DO UPDATE SET
                  parent_id = excluded.parent_id,
                  name = excluded.name,
                  is_dir = excluded.is_dir,
                  size = excluded.size,
                  content_hash = excluded.content_hash,
                  content_version = excluded.content_version,
                  metadata_version = excluded.metadata_version,
                  remote_mtime = excluded.remote_mtime,
                  deleted = excluded.deleted,
                  state = excluded.state,
                  hydrated = excluded.hydrated,
                  pinned = excluded.pinned,
                  dirty = excluded.dirty,
                  local_path = excluded.local_path,
                  last_used_at = excluded.last_used_at,
                  created_at = excluded.created_at,
                  updated_at = excluded.updated_at
                """
            ) { statement in
                try bind(item: item, to: statement)
                _ = try statement.step()
            }
            if item.hydrated, let localPath = item.localPath {
                try upsertCache(
                    ContentCacheRecord(
                        itemID: item.id,
                        localFilePath: localPath,
                        materializedSize: item.size,
                        checksum: item.contentHash,
                        evictable: !item.pinned,
                        lastVerifiedAt: item.updatedAt
                    )
                )
            }
        }
    }

    public func item(id: String) throws -> SyncItem? {
        try queue.sync {
            try connection.withStatement(
                """
                SELECT item_id, parent_id, name, is_dir, size, content_hash, content_version, metadata_version,
                       remote_mtime, deleted, state, hydrated, pinned, dirty, local_path, last_used_at, created_at, updated_at
                FROM items
                WHERE item_id = ?
                LIMIT 1
                """
            ) { statement in
                try statement.bind(1, text: id)
                return try statement.step() ? decodeItem(statement) : nil
            }
        }
    }

    public func children(of parentID: String?) throws -> [SyncItem] {
        try queue.sync {
            let sql: String
            if parentID == nil {
                sql = """
                SELECT item_id, parent_id, name, is_dir, size, content_hash, content_version, metadata_version,
                       remote_mtime, deleted, state, hydrated, pinned, dirty, local_path, last_used_at, created_at, updated_at
                FROM items
                WHERE parent_id IS NULL AND deleted = 0
                ORDER BY is_dir DESC, name COLLATE NOCASE ASC
                """
            } else {
                sql = """
                SELECT item_id, parent_id, name, is_dir, size, content_hash, content_version, metadata_version,
                       remote_mtime, deleted, state, hydrated, pinned, dirty, local_path, last_used_at, created_at, updated_at
                FROM items
                WHERE parent_id = ? AND deleted = 0
                ORDER BY is_dir DESC, name COLLATE NOCASE ASC
                """
            }
            return try connection.withStatement(sql) { statement in
                if let parentID {
                    try statement.bind(1, text: parentID)
                }
                var items: [SyncItem] = []
                while try statement.step() {
                    items.append(try decodeItem(statement))
                }
                return items
            }
        }
    }

    public func tombstone(itemID: String, updatedAt: Date) throws {
        try queue.sync {
            try connection.withStatement(
                """
                UPDATE items
                SET deleted = 1, hydrated = 0, dirty = 0, state = ?, local_path = NULL, updated_at = ?
                WHERE item_id = ?
                """
            ) { statement in
                try statement.bind(1, text: ItemState.cloudOnly.rawValue)
                try statement.bind(2, int64: updatedAt.epochSeconds)
                try statement.bind(3, text: itemID)
                _ = try statement.step()
            }
            try deleteCache(itemID: itemID)
        }
    }

    public func updatePinned(itemID: String, pinned: Bool, updatedAt: Date) throws {
        try queue.sync {
            try connection.withStatement(
                "UPDATE items SET pinned = ?, updated_at = ? WHERE item_id = ?"
            ) { statement in
                try statement.bind(1, int: pinned ? 1 : 0)
                try statement.bind(2, int64: updatedAt.epochSeconds)
                try statement.bind(3, text: itemID)
                _ = try statement.step()
            }
            try connection.withStatement(
                "UPDATE content_cache SET evictable = ? WHERE item_id = ?"
            ) { statement in
                try statement.bind(1, int: pinned ? 0 : 1)
                try statement.bind(2, text: itemID)
                _ = try statement.step()
            }
        }
    }

    public func markHydrated(itemID: String, localPath: String, size: Int64, checksum: String?, lastUsedAt: Date) throws {
        try queue.sync {
            try connection.withStatement(
                """
                UPDATE items
                SET local_path = ?, size = ?, content_hash = COALESCE(?, content_hash), hydrated = 1, dirty = 0,
                    state = ?, last_used_at = ?, updated_at = ?
                WHERE item_id = ?
                """
            ) { statement in
                try statement.bind(1, text: localPath)
                try statement.bind(2, int64: size)
                try statement.bind(3, text: checksum)
                try statement.bind(4, text: ItemState.hydrated.rawValue)
                try statement.bind(5, int64: lastUsedAt.epochSeconds)
                try statement.bind(6, int64: lastUsedAt.epochSeconds)
                try statement.bind(7, text: itemID)
                _ = try statement.step()
            }
            let pinned = try fetchPinned(itemID: itemID)
            try upsertCache(
                ContentCacheRecord(
                    itemID: itemID,
                    localFilePath: localPath,
                    materializedSize: size,
                    checksum: checksum,
                    evictable: !pinned,
                    lastVerifiedAt: lastUsedAt
                )
            )
        }
    }

    public func markCloudOnly(itemID: String, updatedAt: Date) throws {
        try queue.sync {
            try connection.withStatement(
                """
                UPDATE items
                SET hydrated = 0, local_path = NULL, state = ?, updated_at = ?
                WHERE item_id = ?
                """
            ) { statement in
                try statement.bind(1, text: ItemState.cloudOnly.rawValue)
                try statement.bind(2, int64: updatedAt.epochSeconds)
                try statement.bind(3, text: itemID)
                _ = try statement.step()
            }
            try deleteCache(itemID: itemID)
        }
    }

    public func markState(itemID: String, state: ItemState, dirty: Bool, updatedAt: Date) throws {
        try queue.sync {
            try connection.withStatement(
                "UPDATE items SET state = ?, dirty = ?, updated_at = ? WHERE item_id = ?"
            ) { statement in
                try statement.bind(1, text: state.rawValue)
                try statement.bind(2, int: dirty ? 1 : 0)
                try statement.bind(3, int64: updatedAt.epochSeconds)
                try statement.bind(4, text: itemID)
                _ = try statement.step()
            }
        }
    }

    public func recordUse(itemID: String, at: Date) throws {
        try queue.sync {
            try connection.withStatement(
                "UPDATE items SET last_used_at = ?, updated_at = ? WHERE item_id = ?"
            ) { statement in
                try statement.bind(1, int64: at.epochSeconds)
                try statement.bind(2, int64: at.epochSeconds)
                try statement.bind(3, text: itemID)
                _ = try statement.step()
            }
        }
    }

    public func evictionCandidates(limit: Int) throws -> [SyncItem] {
        try queue.sync {
            try connection.withStatement(
                """
                SELECT item_id, parent_id, name, is_dir, size, content_hash, content_version, metadata_version,
                       remote_mtime, deleted, state, hydrated, pinned, dirty, local_path, last_used_at, created_at, updated_at
                FROM items
                WHERE deleted = 0 AND hydrated = 1 AND dirty = 0 AND pinned = 0
                ORDER BY COALESCE(last_used_at, 0) ASC, updated_at ASC
                LIMIT ?
                """
            ) { statement in
                try statement.bind(1, int64: Int64(limit))
                var result: [SyncItem] = []
                while try statement.step() {
                    result.append(try decodeItem(statement))
                }
                return result
            }
        }
    }

    public func totalCachedBytes() throws -> Int64 {
        try queue.sync {
            try connection.withStatement(
                "SELECT COALESCE(SUM(materialized_size), 0) FROM content_cache"
            ) { statement in
                guard try statement.step() else { return 0 }
                return statement.int64(at: 0)
            }
        }
    }

    public func save(syncState: SyncCursorState) throws {
        try queue.sync {
            try connection.withStatement(
                """
                INSERT INTO sync_state (domain_id, remote_cursor, working_set_cursor, last_full_sync_at, last_push_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(domain_id) DO UPDATE SET
                  remote_cursor = excluded.remote_cursor,
                  working_set_cursor = excluded.working_set_cursor,
                  last_full_sync_at = excluded.last_full_sync_at,
                  last_push_at = excluded.last_push_at
                """
            ) { statement in
                try statement.bind(1, text: syncState.domainID)
                try statement.bind(2, text: syncState.remoteCursor)
                try statement.bind(3, text: syncState.workingSetCursor)
                try statement.bind(4, int64: syncState.lastFullSyncAt?.epochSeconds)
                try statement.bind(5, int64: syncState.lastPushAt?.epochSeconds)
                _ = try statement.step()
            }
        }
    }

    public func syncState(domainID: String) throws -> SyncCursorState? {
        try queue.sync {
            try connection.withStatement(
                """
                SELECT domain_id, remote_cursor, working_set_cursor, last_full_sync_at, last_push_at
                FROM sync_state
                WHERE domain_id = ?
                LIMIT 1
                """
            ) { statement in
                try statement.bind(1, text: domainID)
                guard try statement.step() else { return nil }
                return SyncCursorState(
                    domainID: statement.text(at: 0) ?? domainID,
                    remoteCursor: statement.text(at: 1),
                    workingSetCursor: statement.text(at: 2),
                    lastFullSyncAt: Date(epochSeconds: statement.int64OrNil(at: 3)),
                    lastPushAt: Date(epochSeconds: statement.int64OrNil(at: 4))
                )
            }
        }
    }

    public func enqueue(_ operation: PendingOperation) throws {
        try queue.sync {
            try connection.withStatement(
                """
                INSERT INTO pending_ops (op_id, item_id, op_type, base_content_version, base_metadata_version, payload_json, state, retry_count, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(op_id) DO UPDATE SET
                  item_id = excluded.item_id,
                  op_type = excluded.op_type,
                  base_content_version = excluded.base_content_version,
                  base_metadata_version = excluded.base_metadata_version,
                  payload_json = excluded.payload_json,
                  state = excluded.state,
                  retry_count = excluded.retry_count,
                  created_at = excluded.created_at,
                  updated_at = excluded.updated_at
                """
            ) { statement in
                try bind(operation: operation, to: statement)
                _ = try statement.step()
            }
        }
    }

    public func pendingOperations(in states: [OperationLifecycleState]) throws -> [PendingOperation] {
        try queue.sync {
            guard !states.isEmpty else { return [] }
            let placeholders = states.enumerated().map { index, _ in index == 0 ? "?" : ", ?" }.joined()
            let sql = """
            SELECT op_id, item_id, op_type, base_content_version, base_metadata_version, payload_json, state, retry_count, created_at, updated_at
            FROM pending_ops
            WHERE state IN (\(placeholders))
            ORDER BY created_at ASC
            """
            return try connection.withStatement(sql) { statement in
                for (index, state) in states.enumerated() {
                    try statement.bind(Int32(index + 1), text: state.rawValue)
                }
                var operations: [PendingOperation] = []
                while try statement.step() {
                    operations.append(try decodeOperation(statement))
                }
                return operations
            }
        }
    }

    public func updateOperationState(id: String, state: OperationLifecycleState, retryCount: Int, updatedAt: Date) throws {
        try queue.sync {
            try connection.withStatement(
                "UPDATE pending_ops SET state = ?, retry_count = ?, updated_at = ? WHERE op_id = ?"
            ) { statement in
                try statement.bind(1, text: state.rawValue)
                try statement.bind(2, int64: Int64(retryCount))
                try statement.bind(3, int64: updatedAt.epochSeconds)
                try statement.bind(4, text: id)
                _ = try statement.step()
            }
        }
    }

    public func save(transfer: TransferRecord) throws {
        try queue.sync {
            try connection.withStatement(
                """
                INSERT INTO transfers (transfer_id, item_id, direction, temp_path, bytes_done, bytes_total, resume_token, state, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(transfer_id) DO UPDATE SET
                  item_id = excluded.item_id,
                  direction = excluded.direction,
                  temp_path = excluded.temp_path,
                  bytes_done = excluded.bytes_done,
                  bytes_total = excluded.bytes_total,
                  resume_token = excluded.resume_token,
                  state = excluded.state,
                  created_at = excluded.created_at,
                  updated_at = excluded.updated_at
                """
            ) { statement in
                try bind(transfer: transfer, to: statement)
                _ = try statement.step()
            }
        }
    }

    public func transfer(id: String) throws -> TransferRecord? {
        try queue.sync {
            try connection.withStatement(
                """
                SELECT transfer_id, item_id, direction, temp_path, bytes_done, bytes_total, resume_token, state, created_at, updated_at
                FROM transfers
                WHERE transfer_id = ?
                LIMIT 1
                """
            ) { statement in
                try statement.bind(1, text: id)
                return try statement.step() ? decodeTransfer(statement) : nil
            }
        }
    }

    private func bind(item: SyncItem, to statement: SQLiteStatement) throws {
        try statement.bind(1, text: item.id)
        try statement.bind(2, text: item.parentID)
        try statement.bind(3, text: item.name)
        try statement.bind(4, int: item.kind == .directory ? 1 : 0)
        try statement.bind(5, int64: item.size)
        try statement.bind(6, text: item.contentHash)
        try statement.bind(7, text: item.contentVersion)
        try statement.bind(8, text: item.metadataVersion)
        try statement.bind(9, int64: item.remoteModifiedAt?.epochSeconds)
        try statement.bind(10, int: item.deleted ? 1 : 0)
        try statement.bind(11, text: item.state.rawValue)
        try statement.bind(12, int: item.hydrated ? 1 : 0)
        try statement.bind(13, int: item.pinned ? 1 : 0)
        try statement.bind(14, int: item.dirty ? 1 : 0)
        try statement.bind(15, text: item.localPath)
        try statement.bind(16, int64: item.lastUsedAt?.epochSeconds)
        try statement.bind(17, int64: item.createdAt.epochSeconds)
        try statement.bind(18, int64: item.updatedAt.epochSeconds)
    }

    private func bind(operation: PendingOperation, to statement: SQLiteStatement) throws {
        try statement.bind(1, text: operation.id)
        try statement.bind(2, text: operation.itemID)
        try statement.bind(3, text: operation.type.rawValue)
        try statement.bind(4, text: operation.baseContentVersion)
        try statement.bind(5, text: operation.baseMetadataVersion)
        try statement.bind(6, text: operation.payloadJSON)
        try statement.bind(7, text: operation.state.rawValue)
        try statement.bind(8, int64: Int64(operation.retryCount))
        try statement.bind(9, int64: operation.createdAt.epochSeconds)
        try statement.bind(10, int64: operation.updatedAt.epochSeconds)
    }

    private func bind(transfer: TransferRecord, to statement: SQLiteStatement) throws {
        try statement.bind(1, text: transfer.id)
        try statement.bind(2, text: transfer.itemID)
        try statement.bind(3, text: transfer.direction.rawValue)
        try statement.bind(4, text: transfer.tempPath)
        try statement.bind(5, int64: transfer.bytesDone)
        try statement.bind(6, int64: transfer.bytesTotal)
        try statement.bind(7, text: transfer.resumeToken)
        try statement.bind(8, text: transfer.state.rawValue)
        try statement.bind(9, int64: transfer.createdAt.epochSeconds)
        try statement.bind(10, int64: transfer.updatedAt.epochSeconds)
    }

    private func upsertCache(_ cache: ContentCacheRecord) throws {
        try connection.withStatement(
            """
            INSERT INTO content_cache (item_id, local_file_path, materialized_size, checksum, evictable, last_verified_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(item_id) DO UPDATE SET
              local_file_path = excluded.local_file_path,
              materialized_size = excluded.materialized_size,
              checksum = excluded.checksum,
              evictable = excluded.evictable,
              last_verified_at = excluded.last_verified_at
            """
        ) { statement in
            try statement.bind(1, text: cache.itemID)
            try statement.bind(2, text: cache.localFilePath)
            try statement.bind(3, int64: cache.materializedSize)
            try statement.bind(4, text: cache.checksum)
            try statement.bind(5, int: cache.evictable ? 1 : 0)
            try statement.bind(6, int64: cache.lastVerifiedAt?.epochSeconds)
            _ = try statement.step()
        }
    }

    private func deleteCache(itemID: String) throws {
        try connection.withStatement(
            "DELETE FROM content_cache WHERE item_id = ?"
        ) { statement in
            try statement.bind(1, text: itemID)
            _ = try statement.step()
        }
    }

    private func fetchPinned(itemID: String) throws -> Bool {
        try connection.withStatement(
            "SELECT pinned FROM items WHERE item_id = ? LIMIT 1"
        ) { statement in
            try statement.bind(1, text: itemID)
            guard try statement.step() else { return false }
            return statement.int(at: 0) == 1
        }
    }

    private func decodeItem(_ statement: SQLiteStatement) throws -> SyncItem {
        let stateRaw = statement.text(at: 10) ?? ItemState.cloudOnly.rawValue
        guard let state = ItemState(rawValue: stateRaw) else {
            throw CloudPlaceholderError.invalidState("Unknown item state \(stateRaw)")
        }
        return SyncItem(
            id: statement.text(at: 0) ?? "",
            parentID: statement.text(at: 1),
            name: statement.text(at: 2) ?? "",
            kind: statement.int(at: 3) == 1 ? .directory : .file,
            size: statement.int64(at: 4),
            contentHash: statement.text(at: 5),
            contentVersion: statement.text(at: 6),
            metadataVersion: statement.text(at: 7),
            remoteModifiedAt: Date(epochSeconds: statement.int64OrNil(at: 8)),
            deleted: statement.int(at: 9) == 1,
            state: state,
            hydrated: statement.int(at: 11) == 1,
            pinned: statement.int(at: 12) == 1,
            dirty: statement.int(at: 13) == 1,
            localPath: statement.text(at: 14),
            lastUsedAt: Date(epochSeconds: statement.int64OrNil(at: 15)),
            createdAt: Date(epochSeconds: statement.int64(at: 16)),
            updatedAt: Date(epochSeconds: statement.int64(at: 17))
        )
    }

    private func decodeOperation(_ statement: SQLiteStatement) throws -> PendingOperation {
        guard
            let typeRaw = statement.text(at: 2),
            let type = PendingOperationType(rawValue: typeRaw),
            let stateRaw = statement.text(at: 6),
            let state = OperationLifecycleState(rawValue: stateRaw)
        else {
            throw CloudPlaceholderError.invalidState("Unable to decode pending operation")
        }
        return PendingOperation(
            id: statement.text(at: 0) ?? "",
            itemID: statement.text(at: 1) ?? "",
            type: type,
            baseContentVersion: statement.text(at: 3),
            baseMetadataVersion: statement.text(at: 4),
            payloadJSON: statement.text(at: 5) ?? "{}",
            state: state,
            retryCount: Int(statement.int64(at: 7)),
            createdAt: Date(epochSeconds: statement.int64(at: 8)),
            updatedAt: Date(epochSeconds: statement.int64(at: 9))
        )
    }

    private func decodeTransfer(_ statement: SQLiteStatement) throws -> TransferRecord {
        guard
            let directionRaw = statement.text(at: 2),
            let direction = TransferDirection(rawValue: directionRaw),
            let stateRaw = statement.text(at: 7),
            let state = TransferLifecycleState(rawValue: stateRaw)
        else {
            throw CloudPlaceholderError.invalidState("Unable to decode transfer")
        }
        return TransferRecord(
            id: statement.text(at: 0) ?? "",
            itemID: statement.text(at: 1) ?? "",
            direction: direction,
            tempPath: statement.text(at: 3) ?? "",
            bytesDone: statement.int64(at: 4),
            bytesTotal: statement.int64(at: 5),
            resumeToken: statement.text(at: 6),
            state: state,
            createdAt: Date(epochSeconds: statement.int64(at: 8)),
            updatedAt: Date(epochSeconds: statement.int64(at: 9))
        )
    }
}

private extension SQLiteStatement {
    func bind(_ index: Int32, int64: Int64?) throws {
        if let int64 {
            try bind(index, int64: int64)
        } else {
            try bindNull(index)
        }
    }

    func int64OrNil(at column: Int32) -> Int64? {
        isNull(at: column) ? nil : int64(at: column)
    }
}

private extension Date {
    init(epochSeconds: Int64) {
        self = Date(timeIntervalSince1970: TimeInterval(epochSeconds))
    }

    init?(epochSeconds: Int64?) {
        guard let epochSeconds else { return nil }
        self = Date(timeIntervalSince1970: TimeInterval(epochSeconds))
    }

    var epochSeconds: Int64 {
        Int64(timeIntervalSince1970.rounded())
    }
}
