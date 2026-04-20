# Enterprise Cloud Placeholder Sync v1

一个从零起步的企业私有云占位符同步系统原型，目标是验证以下三件事：

- `macOS` 客户端能以 `File Provider` 语义建模 Finder 占位符目录
- 本地同步核心能基于 `SQLite` 跑通增量同步、按需下载、上传和驱逐
- 服务端能提供最小可用的 `Control Plane + Data Plane` mock API

## 目录结构

- `client/`
  - `CloudPlaceholderDomain`：共享领域模型、状态枚举、schema、repo 协议
  - `CloudPlaceholderPersistence`：SQLite bridge 与状态库实现
  - `CloudPlaceholderSync`：同步核心、HTTP remote client、上传/下载/驱逐流程
  - `CloudPlaceholderFileProviderKit`：可嵌入 Xcode extension target 的 File Provider bridge
  - `cloudsync-demo`：命令行 demo
- `macos/`
  - `EnterpriseCloudDrive.xcodeproj`：真正的 macOS App + File Provider Extension 工程
  - `EnterpriseCloudDriveApp`：菜单栏 App、domain 注册、mock server 配置入口
  - `EnterpriseCloudDriveFileProvider`：`NSFileProviderReplicatedExtension` principal class
- `server/`
  - `mock-server.mjs`：无外部依赖的 mock server
  - `admin-console.html`：简单管理台
- `docs/`
  - 产品、接口、架构与开发文档
- `data/`
  - mock server 对象数据与元数据持久化目录

## 已实现内容

- 本地 SQLite 状态库与 5 张核心表
- 远端变更拉取、按需下载、上传提交、冷文件驱逐
- 忽略 `.DS_Store`、`._*`、Office 锁文件等系统噪音
- 基于 `NSFileProviderItem` / `NSFileProviderEnumerator` 的桥接层
- 一个可由 `xcodebuild` 成功编译的 `macOS App + File Provider Extension` 工程
- 设备注册、增量变更、Range 下载、审计查询的 mock API
- Swift 测试与 Node 测试

## 快速开始

### 1. 跑客户端测试

```bash
cd client
swift test --disable-sandbox
```

### 2. 跑服务端测试

```bash
cd server
node --test mock-server.test.mjs
```

### 3. 启动 mock server

```bash
cd server
node mock-server.mjs
```

启动后可访问：

- `http://127.0.0.1:8787/health`
- `http://127.0.0.1:8787/admin`

### 4. 运行客户端 demo

```bash
cd client
MOCK_SERVER_URL=http://127.0.0.1:8787 swift run cloudsync-demo --disable-sandbox
```

如果不设置 `MOCK_SERVER_URL`，demo 会只初始化本地状态库。

### 5. 构建 macOS App + File Provider Extension

```bash
cd macos
xcodebuild -project EnterpriseCloudDrive.xcodeproj -scheme EnterpriseCloudDrive -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Xcode 工程入口：

- [EnterpriseCloudDrive.xcodeproj](/Users/peiel/Documents/Codex/2026-04-17-icloud-onedrive-cloud-placeholders-1-the/macos/EnterpriseCloudDrive.xcodeproj/project.pbxproj)
- [EnterpriseCloudDriveApp.swift](/Users/peiel/Documents/Codex/2026-04-17-icloud-onedrive-cloud-placeholders-1-the/macos/EnterpriseCloudDriveApp/EnterpriseCloudDriveApp.swift)
- [FileProviderExtension.swift](/Users/peiel/Documents/Codex/2026-04-17-icloud-onedrive-cloud-placeholders-1-the/macos/EnterpriseCloudDriveFileProvider/FileProviderExtension.swift)

## 当前边界

- 现在已有完整的 Xcode `App + File Provider Extension target`，但仍是开发态工程
- `CloudPlaceholderFileProviderKit` 已被接入 extension principal class，但 Finder 侧真实行为仍需带 entitlement 的安装运行验证
- 服务端仍是单进程 mock，不包含真实身份系统、对象存储适配器和多租户隔离
- v1 原型以“文件级同步正确性”优先，尚未实现 partial fetch / push notification

## 文档入口

- [产品设计](/Users/peiel/Documents/Codex/2026-04-17-icloud-onedrive-cloud-placeholders-1-the/docs/product-design.md)
- [接口契约](/Users/peiel/Documents/Codex/2026-04-17-icloud-onedrive-cloud-placeholders-1-the/docs/api-contract.md)
- [架构图与流转图](/Users/peiel/Documents/Codex/2026-04-17-icloud-onedrive-cloud-placeholders-1-the/docs/architecture.md)
- [开发运行手册](/Users/peiel/Documents/Codex/2026-04-17-icloud-onedrive-cloud-placeholders-1-the/docs/dev-runbook.md)
