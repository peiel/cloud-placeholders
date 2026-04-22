[根目录](../CLAUDE.md) > **client**

# client -- 核心同步库

## 模块职责

Swift Package，包含企业云占位符同步的全部核心逻辑。以 Swift 6.1 编写，面向 macOS 15+，提供 4 个 library target 和 1 个可执行 target。

## 入口与启动

- **Package 定义**：`Package.swift` -- 声明所有 target、依赖关系、链接设置
- **CLI Demo 入口**：`Sources/cloudsync-demo/main.swift` -- `@main` 可执行文件，演示本地库初始化、设备注册、增量同步、文件上传全流程
- **运行方式**：`MOCK_SERVER_URL=http://127.0.0.1:8787 swift run cloudsync-demo --disable-sandbox`

## Target 依赖关系

```
CloudPlaceholderDomain (无依赖)
    |
    v
CloudPlaceholderPersistence (依赖 Domain，链接 sqlite3)
    |
    v
CloudPlaceholderSync (依赖 Domain + Persistence)
    |
    v
CloudPlaceholderFileProviderKit (依赖 Domain + Persistence + Sync)
```

`cloudsync-demo` 依赖 Domain + Persistence + Sync（不依赖 FileProviderKit）。

## 对外接口

### CloudPlaceholderDomain

纯模型层，零依赖。定义了所有共享类型：

- **模型结构体**：`SyncItem`、`SyncCursorState`、`PendingOperation`、`TransferRecord`、`ContentCacheRecord`、`DevicePolicy`、`RemoteChangeBatch`、`UploadDescriptor`、`RemoteCommitResult`、`DeviceRegistration`、`AuditEvent`
- **枚举**：`DeploymentMode`、`ItemKind`、`ItemState`、`PendingOperationType`、`OperationLifecycleState`、`TransferDirection`、`TransferLifecycleState`
- **协议**：`MetadataStore`（19 个方法）、`RemoteAPIClient`（4 个方法）
- **错误**：`CloudPlaceholderError`（sqlite / missingItem / invalidState / versionConflict / ignoredSystemFile / network）
- **工具**：`IgnoredSystemFileMatcher`、`CloudPlaceholderSchema`（DDL 字符串）

### CloudPlaceholderPersistence

- `SQLiteMetadataStore`：`MetadataStore` 协议的完整实现，基于 `DispatchQueue` 串行化 + 原始 SQLite C API
- `SQLiteConnection` / `SQLiteStatement`：底层 SQLite C 绑定封装

### CloudPlaceholderSync

- `SyncEngine`：同步编排器，核心方法：
  - `register(device:)` -- 设备注册
  - `syncDown()` -- 增量拉取远端变更
  - `materializeItem(itemID:cacheDirectory:)` -- 按需下载
  - `stageLocalFile(itemID:parentID:fileURL:)` -- 暂存本地修改
  - `flushPendingUploads()` -- 批量上传
  - `evictColdFiles(maximumCachedBytes:)` -- 冷文件驱逐
- `HTTPRemoteAPIClient`：`RemoteAPIClient` 协议的 HTTP 实现
- `UploadPayload`：上传载荷编码结构

### CloudPlaceholderFileProviderKit

- `PlaceholderFileProviderItem`：`NSFileProviderItem` 实现，将 `SyncItem` 映射为 Finder 可识别的文件属性
- `PlaceholderEnumerator`：`NSFileProviderEnumerator` 实现，支持枚举与变更通知
- `ProviderDomainController`：Extension 主控制器，桥接 `MetadataStore` + `SyncEngine` 与 FileProvider 框架

## 关键依赖与配置

- **系统依赖**：`sqlite3`（通过 `.linkedLibrary("sqlite3")` 链接）、`CryptoKit`（SHA256）、`FileProvider`、`UniformTypeIdentifiers`
- **平台要求**：macOS 15+
- **Swift 版本**：6.1（严格并发）
- **外部包依赖**：无（零第三方依赖）

## 数据模型

### SQLite Schema（5 张表）

| 表名 | 说明 |
|------|------|
| `items` | 文件/目录元数据（18 列），含 parent_id 树形结构 |
| `sync_state` | 同步游标状态（每个 domain 一条记录） |
| `pending_ops` | 待执行操作队列（create/modify/move/delete） |
| `transfers` | 传输记录（上传/下载进度跟踪） |
| `content_cache` | 本地缓存文件索引（用于驱逐策略） |

关键索引：`idx_items_parent`、`idx_items_deleted`、`idx_items_last_used`、`idx_pending_state`

## 测试与质量

- **测试框架**：Swift Testing（`@Test` / `#expect` / `#require`）
- **测试 Target**：
  - `CloudPlaceholderPersistenceTests`（`Tests/CloudPlaceholderPersistenceTests/SQLiteStoreTests.swift`）：2 个测试用例，覆盖持久化 CRUD、缓存统计、驱逐候选、待处理操作
  - `CloudPlaceholderSyncTests`（`Tests/CloudPlaceholderSyncTests/SyncEngineTests.swift`）：2 个测试用例，使用 `RemoteAPIStub` mock 远端，覆盖增量同步 + 上传 + 驱逐
- **运行命令**：`swift test --disable-sandbox`
- **质量工具**：无（无 lint/format 配置）

## 常见问题 (FAQ)

- **Q: 为什么用 `@_silgen_name` 而不是 `sqlite3` Swift 包？**
  A: 避免引入第三方依赖，直接链接系统 sqlite3 库，保持零依赖设计。
- **Q: 为什么 `SyncEngine` 标记 `@unchecked Sendable`？**
  A: `SQLiteMetadataStore` 内部通过 `DispatchQueue` 串行化访问，保证线程安全，但编译器无法自动推断。
- **Q: demo 不连 mock server 能跑吗？**
  A: 可以，不设置 `MOCK_SERVER_URL` 环境变量时，demo 只初始化本地 SQLite 状态库并打印提示。

## 相关文件清单

```
client/
  Package.swift                                    -- Swift Package 定义
  Sources/
    CloudPlaceholderDomain/
      DomainModels.swift                            -- 所有领域模型、协议、错误类型
      Schema.swift                                  -- SQLite DDL
    CloudPlaceholderPersistence/
      SQLiteBridge.swift                            -- SQLite C API 绑定
      SQLiteStore.swift                             -- MetadataStore 实现
    CloudPlaceholderSync/
      SyncEngine.swift                              -- 同步引擎 + HTTP 客户端
    CloudPlaceholderFileProviderKit/
      PlaceholderFileProviderBridge.swift           -- FileProvider 桥接层
    cloudsync-demo/
      main.swift                                    -- CLI demo 入口
  Tests/
    CloudPlaceholderPersistenceTests/
      SQLiteStoreTests.swift                        -- 持久化测试
    CloudPlaceholderSyncTests/
      SyncEngineTests.swift                         -- 同步引擎测试
```

## 变更记录 (Changelog)

| 时间 | 操作 | 说明 |
|------|------|------|
| 2026-04-22T21:54:18 | 初始化 | 首次生成模块文档 |
