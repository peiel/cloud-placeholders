# Enterprise Cloud Placeholder Sync v1 架构图

这份文档描述的是当前仓库里已经落地的实现结构，不是未来完整产品的目标态蓝图。

## 当前实现架构图

```mermaid
flowchart LR
    User["用户 / Finder / 本地文档应用"] --> App["EnterpriseCloudDriveApp<br/>菜单栏 App / Settings"]
    User --> FP["EnterpriseCloudDriveFileProvider<br/>NSFileProviderReplicatedExtension"]

    App --> Installer["FileProviderDomainInstaller"]
    Installer --> System["NSFileProviderManager.add(primary)"]
    App --> Defaults["App Group UserDefaults<br/>MockServerURL"]

    System --> FP
    FP --> Runtime["ExtensionRuntime.bootstrap"]
    Runtime --> Shared["App Group Shared Container<br/>EnterpriseCloudDriveShared/primary"]
    Runtime --> Store["SQLiteMetadataStore<br/>state.sqlite"]
    Runtime --> Cache["cache/"]
    Runtime --> Staging["staging/"]
    Runtime --> Sync["SyncEngine"]
    Runtime --> Controller["ProviderDomainController"]
    Runtime --> Defaults

    Controller --> Bridge["PlaceholderEnumerator / PlaceholderFileProviderItem"]
    Controller --> Store
    Controller --> Sync

    Sync --> Store
    Sync --> Cache
    Sync --> Staging
    Sync --> API["HTTPRemoteAPIClient"]

    API --> Server["mock-server.mjs"]
    Admin["admin-console.html"] --> Server
    Server --> State["data/server-state.json<br/>items / changes / devices / audit / policies"]
    Server --> Blob["data/blob-store"]
```

## 关键流转图

### 1. 启动与挂载

```mermaid
sequenceDiagram
    participant User as 用户
    participant App as EnterpriseCloudDriveApp
    participant Defaults as App Group UserDefaults
    participant Installer as FileProviderDomainInstaller
    participant System as NSFileProviderManager
    participant FP as FileProviderExtension
    participant Shared as Shared Container
    participant DB as SQLiteMetadataStore

    User->>App: 配置 Mock Server URL
    App->>Defaults: 保存 MockServerURL
    User->>App: 点击“注册 File Provider Domain”
    App->>Installer: installPrimaryDomain()
    Installer->>System: add(primary)
    System-->>FP: 拉起 extension
    FP->>Shared: 定位 EnterpriseCloudDriveShared/primary
    FP->>DB: 打开/初始化 state.sqlite
    FP->>Defaults: 读取 MockServerURL
    FP->>FP: 构造 SyncEngine + ProviderDomainController
```

### 2. 按需下载

```mermaid
sequenceDiagram
    participant Finder as Finder / 本地应用
    participant FP as FileProviderExtension
    participant Ctrl as ProviderDomainController
    participant Sync as SyncEngine
    participant DB as SQLiteMetadataStore
    participant Server as mock-server
    participant Blob as blob-store

    Finder->>FP: fetchContents(itemID)
    FP->>Ctrl: fetchContents(for:into:)
    Ctrl->>Sync: materializeItem(itemID, cacheDirectory)
    Sync->>DB: 读取 item / 写入 download transfer
    Sync->>Server: GET /api/items/:id/content
    Server->>Blob: 读取文件字节
    Server-->>Sync: 返回内容
    Sync->>Server: GET /api/items/:id
    Server-->>Sync: 返回最新元数据
    Sync->>Sync: temp 文件移动到 cache/
    Sync->>DB: markHydrated + upsert item
    Ctrl-->>FP: 返回本地 URL + NSFileProviderItem
    FP-->>Finder: 文件可打开
```

### 3. 本地修改上传

```mermaid
sequenceDiagram
    participant User as 用户 / 本地应用
    participant FP as FileProviderExtension
    participant Sync as SyncEngine
    participant DB as SQLiteMetadataStore
    participant Server as mock-server
    participant State as server-state.json
    participant Blob as blob-store

    User->>FP: createItem / modifyItem
    FP->>FP: cloneSystemOwnedFile() 复制到 staging/
    FP->>Sync: stageLocalFile(itemID, parentID, fileURL)
    Sync->>DB: upsert item + enqueue pending op
    FP->>Sync: flushPendingUploads()
    Sync->>Server: POST /api/items/:id/content
    Server->>Blob: 写入二进制内容
    Server->>State: 更新 items / changes / audit / version
    Server-->>Sync: 返回 RemoteCommitResult
    Sync->>DB: 更新 contentVersion / remoteCursor / op done
    FP-->>User: 修改完成并已提交
```

### 4. 冷文件驱逐

```mermaid
sequenceDiagram
    participant Policy as 缓存策略调用方
    participant Sync as SyncEngine
    participant DB as SQLiteMetadataStore
    participant Cache as 本地 cache/

    Policy->>Sync: evictColdFiles(maximumCachedBytes)
    Sync->>DB: totalCachedBytes()
    Sync->>DB: evictionCandidates(hydrated=1, dirty=0, pinned=0)
    Sync->>Cache: 删除本地 materialized 文件
    Sync->>DB: markCloudOnly(itemID)
```

## 当前态与目标态差距

- 已打通：
  - App 侧 domain 注册
  - Extension 启动与共享运行时初始化
  - 文件内容按需下载
  - 本地文件修改后上传
  - 基于 SQLite 的缓存与驱逐状态管理
- 还未完全打通：
  - `syncDown()` 尚未自动接入 App 或 Extension 的首轮同步流程
  - 设备注册 `register(device)` 已在同步层实现，但尚未接进 macOS 主链路
  - 目录创建、删除、重命名、移动还没有完整的远端元数据闭环
  - 自动驱逐逻辑已实现，但还没有接成常驻后台调度
  - Finder 真实占位符体验仍需带 entitlement 的安装运行验证

## 代码映射

- App:
  - [EnterpriseCloudDriveApp.swift](/Users/peiel/Documents/Codex/2026-04-17-icloud-onedrive-cloud-placeholders-1-the/macos/EnterpriseCloudDriveApp/EnterpriseCloudDriveApp.swift)
  - [FileProviderDomainInstaller.swift](/Users/peiel/Documents/Codex/2026-04-17-icloud-onedrive-cloud-placeholders-1-the/macos/EnterpriseCloudDriveApp/FileProviderDomainInstaller.swift)
- File Provider:
  - [FileProviderExtension.swift](/Users/peiel/Documents/Codex/2026-04-17-icloud-onedrive-cloud-placeholders-1-the/macos/EnterpriseCloudDriveFileProvider/FileProviderExtension.swift)
  - [PlaceholderFileProviderBridge.swift](/Users/peiel/Documents/Codex/2026-04-17-icloud-onedrive-cloud-placeholders-1-the/client/Sources/CloudPlaceholderFileProviderKit/PlaceholderFileProviderBridge.swift)
- Sync:
  - [SyncEngine.swift](/Users/peiel/Documents/Codex/2026-04-17-icloud-onedrive-cloud-placeholders-1-the/client/Sources/CloudPlaceholderSync/SyncEngine.swift)
  - [SQLiteStore.swift](/Users/peiel/Documents/Codex/2026-04-17-icloud-onedrive-cloud-placeholders-1-the/client/Sources/CloudPlaceholderPersistence/SQLiteStore.swift)
- Server:
  - [mock-server.mjs](/Users/peiel/Documents/Codex/2026-04-17-icloud-onedrive-cloud-placeholders-1-the/server/mock-server.mjs)
  - [admin-console.html](/Users/peiel/Documents/Codex/2026-04-17-icloud-onedrive-cloud-placeholders-1-the/server/admin-console.html)
