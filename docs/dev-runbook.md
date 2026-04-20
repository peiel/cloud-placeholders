# macOS 本机联调手册

## 目标

让 `EnterpriseCloudDrive.app`、`EnterpriseCloudDriveFileProvider.appex` 和本地 mock server 在同一台 Mac 上完成最小联调。

## 1. 启动 mock server

```bash
cd /Users/peiel/Documents/Codex/2026-04-17-icloud-onedrive-cloud-placeholders-1-the/server
node mock-server.mjs
```

验证：

- `http://127.0.0.1:8787/health`
- `http://127.0.0.1:8787/admin`

## 2. 构建 macOS 工程

```bash
cd /Users/peiel/Documents/Codex/2026-04-17-icloud-onedrive-cloud-placeholders-1-the/macos
xcodebuild -project EnterpriseCloudDrive.xcodeproj -scheme EnterpriseCloudDrive -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

## 3. 启动菜单栏 App

构建产物通常位于：

`~/Library/Developer/Xcode/DerivedData/EnterpriseCloudDrive-*/Build/Products/Debug/EnterpriseCloudDrive.app`

启动后：

- 在 Settings 中确认 `Mock Server URL`
- 点击“保存配置”
- 点击“注册 File Provider Domain”

## 4. 查看共享数据

菜单栏中可直接点击“打开共享数据目录”。

目录下会出现：

- `state.sqlite`
- `cache/`
- `staging/`

这些内容由 App Group 容器承载，App 和 File Provider Extension 共用。

## 5. 当前已知边界

- 目前可以成功构建工程，但真实 Finder 集成仍依赖本机签名、系统扩展加载与 File Provider 权限
- 当前原型没有推送唤醒，远端拉取主要靠显式同步路径
- mock server 仍是单进程本地实现，不适合长期部署
