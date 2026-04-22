# Enterprise Cloud Placeholder Sync v1 架构图

这份文档描述的是仓库当前已经落地的实现结构。

## 当前实现架构图

```mermaid
flowchart LR
    User["用户 / Finder / 本地应用"] --> App["EnterpriseCloudDriveApp<br/>菜单栏 App / Settings / Watcher"]
    User --> FP["EnterpriseCloudDriveFileProvider<br/>NSFileProviderReplicatedExtension"]

    App --> Installer["FileProviderDomainInstaller"]
    Installer --> System["NSFileProviderManager.add(primary)"]
    App --> Config["CloudDriveSharedConfigurationStore<br/>App Group UserDefaults"]
    App --> Watcher["SourceDirectoryWatcher<br/>FSEvents + debounce"]

    System --> FP
    App --> Runtime["CloudDriveRuntime.bootstrap"]
    FP --> Runtime

    Runtime --> Shared["App Group Shared Container<br/>EnterpriseCloudDriveShared/primary"]
    Runtime --> Store["SQLiteMetadataStore<br/>state.sqlite"]
    Runtime --> Cache["cache/"]
    Runtime --> Staging["staging/"]
    Runtime --> Lock["sync.lock"]
    Runtime --> Sync["SyncEngine"]
    Runtime --> Bootstrap["SyncBootstrapCoordinator"]

    Sync --> Store
    Sync --> API["HTTPRemoteAPIClient"]
    Sync --> Local["LocalDirectoryRemoteAPIClient"]

    Watcher --> Bootstrap
    Bootstrap --> Sync

    FP --> Bridge["ProviderDomainController<br/>PlaceholderEnumerator"]
    Bridge --> Store
    Bridge --> Bootstrap

    API --> Server["mock-server.mjs"]
    Local --> Source["本地目录 / 外接盘目录"]
    Server --> Data["data/server-state.json + blob-store"]
```

## 关键流转图

### 1. 启动、注册与首轮同步

```mermaid
sequenceDiagram
    participant User as 用户
    participant App as EnterpriseCloudDriveApp
    participant Config as SharedConfiguration
    participant Installer as FileProviderDomainInstaller
    participant System as NSFileProviderManager
    participant FP as FileProviderExtension
    participant Bootstrap as SyncBootstrapCoordinator
    participant Sync as SyncEngine
    participant Store as SQLiteMetadataStore

    User->>App: 选择 Backend / 目录 / Mock URL
    App->>Config: 保存 backendKind / bookmark / displayName
    User->>App: 注册 File Provider Domain
    App->>Installer: installPrimaryDomain()
    Installer->>System: add(primary) 或复用已有 domain
    System-->>FP: 拉起 extension
    App->>Bootstrap: ensureInitialSync()
    FP->>Bootstrap: ensureInitialSync() 兜底
    Bootstrap->>Sync: syncDown()
    Sync->>Store: 写入 items / source_entries / provider_changes / sync_state
    FP->>FP: Finder 首次枚举前等待最小同步完成
```

### 2. Local Directory 扫描与回放

```mermaid
sequenceDiagram
    participant App as EnterpriseCloudDriveApp
    participant Watcher as SourceDirectoryWatcher
    participant Bootstrap as SyncBootstrapCoordinator
    participant Sync as SyncEngine
    participant Local as LocalDirectoryRemoteAPIClient
    participant Source as 本地目录 / 外接盘
    participant Store as SQLiteMetadataStore
    participant Finder as Finder

    App->>Watcher: 启动 FSEvents
    Source-->>Watcher: 文件变化事件
    Watcher->>Bootstrap: debounce 后触发 forceSync()
    Bootstrap->>Sync: syncDown()
    Sync->>Local: fetchChanges(cursor)
    Local->>Source: 递归扫描目录树
    Local->>Store: 更新 source_entries
    Sync->>Store: 追加 provider_changes
    Sync-->>Finder: signal workingSet / root / 受影响目录
```

### 3. Finder 写入回写源目录

```mermaid
sequenceDiagram
    participant Finder as Finder / 本地应用
    participant FP as FileProviderExtension
    participant Sync as SyncEngine
    participant Local as LocalDirectoryRemoteAPIClient
    participant Source as 本地目录 / 外接盘
    participant Store as SQLiteMetadataStore

    Finder->>FP: createItem / modifyItem / deleteItem
    FP->>Sync: stageLocalFile / stageDirectoryCreation / stageMetadataChange / stageDeletion
    FP->>Sync: flushPendingOperations()
    Sync->>Local: uploadContent / createDirectory / updateMetadata / deleteItem
    Local->>Source: 直接复制、mkdir、rename、move、delete
    Sync->>Store: 更新 items / source_entries / provider_changes / sync_state
    FP-->>Finder: signal 增量枚举
```

### 4. 按需 materialize

```mermaid
sequenceDiagram
    participant Finder as Finder
    participant FP as FileProviderExtension
    participant Ctrl as ProviderDomainController
    participant Sync as SyncEngine
    participant Remote as HTTPRemoteAPIClient / LocalDirectoryRemoteAPIClient
    participant Cache as cache/
    participant Store as SQLiteMetadataStore

    Finder->>FP: fetchContents(itemID)
    FP->>Ctrl: fetchContents(for:into:)
    Ctrl->>Sync: materializeItem(itemID, cacheDirectory)
    Sync->>Remote: downloadContent(itemID)
    Remote-->>Sync: 返回内容与最新元数据
    Sync->>Cache: 写入 materialized 文件
    Sync->>Store: markHydrated + upsert item
    Ctrl-->>Finder: 返回本地 URL + NSFileProviderItem
```

## 当前关键点

- 首轮同步已经接入 App 启动与 Extension 启动兜底，不再要求用户先手工点一次同步
- `sync.lock` 用于串行化 App 与 appex 对同一 `state.sqlite` 的写入
- `workingSetCursor` 明确作为 File Provider 增量锚点，不再复用 `remoteCursor`
- `provider_changes` 负责 working set 与父目录增量枚举，删除会级联记录整棵子树
- `Local Directory` watcher 常驻在菜单栏 App，Extension 只做被系统拉起时的兜底同步

## 代码映射

- App:
  - [EnterpriseCloudDriveApp.swift](/Users/peiel/Project/cloud-placeholders/macos/EnterpriseCloudDriveApp/EnterpriseCloudDriveApp.swift)
  - [SourceDirectoryWatcher.swift](/Users/peiel/Project/cloud-placeholders/macos/EnterpriseCloudDriveApp/SourceDirectoryWatcher.swift)
  - [FileProviderDomainInstaller.swift](/Users/peiel/Project/cloud-placeholders/macos/EnterpriseCloudDriveApp/FileProviderDomainInstaller.swift)
- Shared runtime / sync:
  - [CloudDriveSharedRuntime.swift](/Users/peiel/Project/cloud-placeholders/client/Sources/CloudPlaceholderSync/CloudDriveSharedRuntime.swift)
  - [SyncEngine.swift](/Users/peiel/Project/cloud-placeholders/client/Sources/CloudPlaceholderSync/SyncEngine.swift)
  - [LocalDirectoryRemoteAPIClient.swift](/Users/peiel/Project/cloud-placeholders/client/Sources/CloudPlaceholderSync/LocalDirectoryRemoteAPIClient.swift)
- Persistence / File Provider:
  - [Schema.swift](/Users/peiel/Project/cloud-placeholders/client/Sources/CloudPlaceholderDomain/Schema.swift)
  - [SQLiteStore.swift](/Users/peiel/Project/cloud-placeholders/client/Sources/CloudPlaceholderPersistence/SQLiteStore.swift)
  - [PlaceholderFileProviderBridge.swift](/Users/peiel/Project/cloud-placeholders/client/Sources/CloudPlaceholderFileProviderKit/PlaceholderFileProviderBridge.swift)
  - [FileProviderExtension.swift](/Users/peiel/Project/cloud-placeholders/macos/EnterpriseCloudDriveFileProvider/FileProviderExtension.swift)
- Mock backend:
  - [mock-server.mjs](/Users/peiel/Project/cloud-placeholders/server/mock-server.mjs)
