import Foundation

public enum CloudPlaceholderSchema {
    public static let sql = """
    CREATE TABLE IF NOT EXISTS items (
      item_id TEXT PRIMARY KEY,
      parent_id TEXT,
      name TEXT NOT NULL,
      is_dir INTEGER NOT NULL,
      size INTEGER NOT NULL DEFAULT 0,
      content_hash TEXT,
      content_version TEXT,
      metadata_version TEXT,
      remote_mtime INTEGER,
      deleted INTEGER NOT NULL DEFAULT 0,
      state TEXT NOT NULL,
      hydrated INTEGER NOT NULL DEFAULT 0,
      pinned INTEGER NOT NULL DEFAULT 0,
      dirty INTEGER NOT NULL DEFAULT 0,
      local_path TEXT,
      last_used_at INTEGER,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_items_parent ON items(parent_id);
    CREATE INDEX IF NOT EXISTS idx_items_deleted ON items(deleted);
    CREATE INDEX IF NOT EXISTS idx_items_last_used ON items(last_used_at);

    CREATE TABLE IF NOT EXISTS sync_state (
      domain_id TEXT PRIMARY KEY,
      remote_cursor TEXT,
      working_set_cursor TEXT,
      last_full_sync_at INTEGER,
      last_push_at INTEGER
    );

    CREATE TABLE IF NOT EXISTS pending_ops (
      op_id TEXT PRIMARY KEY,
      item_id TEXT NOT NULL,
      op_type TEXT NOT NULL,
      base_content_version TEXT,
      base_metadata_version TEXT,
      payload_json TEXT NOT NULL,
      state TEXT NOT NULL,
      retry_count INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_pending_state ON pending_ops(state);

    CREATE TABLE IF NOT EXISTS transfers (
      transfer_id TEXT PRIMARY KEY,
      item_id TEXT NOT NULL,
      direction TEXT NOT NULL,
      temp_path TEXT NOT NULL,
      bytes_done INTEGER NOT NULL DEFAULT 0,
      bytes_total INTEGER NOT NULL DEFAULT 0,
      resume_token TEXT,
      state TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS content_cache (
      item_id TEXT PRIMARY KEY,
      local_file_path TEXT NOT NULL,
      materialized_size INTEGER NOT NULL,
      checksum TEXT,
      evictable INTEGER NOT NULL DEFAULT 1,
      last_verified_at INTEGER
    );

    CREATE TABLE IF NOT EXISTS source_entries (
      domain_id TEXT NOT NULL,
      source_id TEXT NOT NULL,
      item_id TEXT NOT NULL,
      parent_source_id TEXT,
      parent_item_id TEXT,
      relative_path TEXT NOT NULL,
      name TEXT NOT NULL,
      is_dir INTEGER NOT NULL,
      size INTEGER NOT NULL DEFAULT 0,
      content_version TEXT,
      metadata_version TEXT,
      remote_mtime INTEGER,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (domain_id, source_id),
      UNIQUE (domain_id, item_id),
      UNIQUE (domain_id, relative_path)
    );

    CREATE INDEX IF NOT EXISTS idx_source_entries_domain_path
    ON source_entries(domain_id, relative_path);

    CREATE TABLE IF NOT EXISTS provider_changes (
      sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      domain_id TEXT NOT NULL,
      item_id TEXT NOT NULL,
      parent_item_id TEXT,
      previous_parent_item_id TEXT,
      change_type TEXT NOT NULL,
      deleted INTEGER NOT NULL DEFAULT 0,
      changed_at INTEGER NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_provider_changes_domain_sequence
    ON provider_changes(domain_id, sequence);
    """
}
