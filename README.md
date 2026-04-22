# Enterprise Cloud Placeholder Sync v1

一个面向 macOS File Provider 的原型工程，用来验证两条端到端链路：

- `Mock Server` 后端：保留现有 HTTP mock，同步、下载、上传、改名、删除都可回归
- `Local Directory` 后端：把任意本地目录或外接盘目录映射成 Finder 可见的 File Provider 树

当前仓库已经接通：

- App / Extension 共享配置与共享 SQLite 状态库
- 启动时首轮 `syncDown()`，Finder 首次枚举会等待最小同步完成
- 本地目录后端的全量扫描、增量 diff、按需 materialize、Finder 写回
- `provider_changes` 驱动的 working set / 容器增量枚举
- 菜单栏 App 托管的 `FSEvents` 监听与 debounce 同步
- 可提交到仓库的签名 `.xcconfig`，以及本机覆盖用的 `Signing.local.xcconfig`

## 目录结构

- `client/`
  - `CloudPlaceholderDomain`：领域模型、schema、共享协议
  - `CloudPlaceholderPersistence`：SQLite bridge 与状态库
  - `CloudPlaceholderSync`：同步引擎、HTTP / 本地目录后端、共享运行时
  - `CloudPlaceholderFileProviderKit`：File Provider bridge
  - `cloudsync-demo`：命令行 demo
- `macos/`
  - `EnterpriseCloudDriveApp`：菜单栏 App、配置 UI、domain 注册、目录监听
  - `EnterpriseCloudDriveFileProvider`：`NSFileProviderReplicatedExtension`
  - `Config/`：entitlements、签名 xcconfig
- `server/`
  - `mock-server.mjs`：无外部依赖的 mock server
  - `admin-console.html`：简单管理台
- `docs/`
  - 接口、架构、联调手册

## 已实现能力

- `syncDown()` 已接入 App 启动和 Extension 启动兜底链路
- `RemoteAPIClient` 已支持文件写入、目录创建、重命名 / 移动、删除
- `LocalDirectoryRemoteAPIClient` 已支持目录扫描 diff 与直接回写源目录
- `source_entries` 持久化源目录索引，`provider_changes` 持久化 File Provider 增量锚点
- Finder 写操作统一走 `SyncEngine.stage* + flushPendingOperations()`
- 每次同步或本地写回后都会 signal `.workingSet`、`.rootContainer` 和受影响目录
- App / appex 都支持 security-scoped bookmark 解析；外接盘断开时保留最近一次索引结果

## 快速开始

### 1. 跑 Swift 测试

```bash
cd /Users/peiel/Project/cloud-placeholders/client
swift test --disable-sandbox
```

### 2. 跑 Node 测试

```bash
cd /Users/peiel/Project/cloud-placeholders/server
node --test mock-server.test.mjs
```

### 3. 启动 mock server

```bash
cd /Users/peiel/Project/cloud-placeholders/server
node mock-server.mjs
```

健康检查与管理台：

- [health](http://127.0.0.1:8787/health)
- [admin](http://127.0.0.1:8787/admin)

### 4. 构建 macOS App + File Provider Extension

无签名开发构建：

```bash
cd /Users/peiel/Project/cloud-placeholders/macos
xcodebuild -project EnterpriseCloudDrive.xcodeproj -scheme EnterpriseCloudDrive -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

这个路径只验证编译，不会让 Finder 里的 File Provider 真正生效。

### 5. 真机联调两种模式

`Mock Server`：

- 启动菜单栏 App
- 在 Settings 里选择 `Mock Server`
- 设置 `Mock Server URL`
- 点击“注册 File Provider Domain”

`Local Directory`：

- 启动菜单栏 App
- 在 Settings 里选择 `Local Directory`
- 选择一个本地目录或外接盘目录
- 点击“注册 File Provider Domain”
- 等待首轮同步完成后，在 Finder 中查看根目录树

签名与 Finder 真机联调步骤见：

- [开发运行手册](/Users/peiel/Project/cloud-placeholders/docs/dev-runbook.md)

## 当前边界

- 第一阶段只支持一个 source root / 一个 File Provider domain
- `Local Directory` fallback 仍优先依赖文件系统 resource identifier；缺失时会退回生成式 source id
- mock server 仍是单进程本地实现，不包含真实认证、对象存储或推送唤醒
- 真正的 Finder 行为仍需要带有效 Apple Developer 签名的本机安装验证

## 代码入口

- [SyncEngine.swift](/Users/peiel/Project/cloud-placeholders/client/Sources/CloudPlaceholderSync/SyncEngine.swift)
- [CloudDriveSharedRuntime.swift](/Users/peiel/Project/cloud-placeholders/client/Sources/CloudPlaceholderSync/CloudDriveSharedRuntime.swift)
- [LocalDirectoryRemoteAPIClient.swift](/Users/peiel/Project/cloud-placeholders/client/Sources/CloudPlaceholderSync/LocalDirectoryRemoteAPIClient.swift)
- [PlaceholderFileProviderBridge.swift](/Users/peiel/Project/cloud-placeholders/client/Sources/CloudPlaceholderFileProviderKit/PlaceholderFileProviderBridge.swift)
- [EnterpriseCloudDriveApp.swift](/Users/peiel/Project/cloud-placeholders/macos/EnterpriseCloudDriveApp/EnterpriseCloudDriveApp.swift)
- [SourceDirectoryWatcher.swift](/Users/peiel/Project/cloud-placeholders/macos/EnterpriseCloudDriveApp/SourceDirectoryWatcher.swift)
- [FileProviderExtension.swift](/Users/peiel/Project/cloud-placeholders/macos/EnterpriseCloudDriveFileProvider/FileProviderExtension.swift)
- [Signing.xcconfig](/Users/peiel/Project/cloud-placeholders/macos/Config/Signing.xcconfig)

## 文档入口

- [产品设计](/Users/peiel/Project/cloud-placeholders/docs/product-design.md)
- [接口契约](/Users/peiel/Project/cloud-placeholders/docs/api-contract.md)
- [架构图与流转图](/Users/peiel/Project/cloud-placeholders/docs/architecture.md)
- [开发运行手册](/Users/peiel/Project/cloud-placeholders/docs/dev-runbook.md)
