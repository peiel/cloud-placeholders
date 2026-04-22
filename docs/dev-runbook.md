# macOS 本机联调手册

这份 runbook 对应当前仓库已经实现的第一阶段 MVP：Finder 可见、`Local Directory` 后端可回写、签名配置可落地到真机。

## 1. 回归基础测试

```bash
cd /Users/peiel/Project/cloud-placeholders/client
swift test --disable-sandbox

cd /Users/peiel/Project/cloud-placeholders/server
node --test mock-server.test.mjs

cd /Users/peiel/Project/cloud-placeholders/macos
xcodebuild -project EnterpriseCloudDrive.xcodeproj -scheme EnterpriseCloudDrive -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

说明：

- `CODE_SIGNING_ALLOWED=NO` 只用于验证工程可编译
- File Provider 想在 Finder 里真正生效，必须改成有效签名构建

## 2. 启动 mock server（可选）

如果要走 HTTP mock 路径：

```bash
cd /Users/peiel/Project/cloud-placeholders/server
node mock-server.mjs
```

验证：

- [health](http://127.0.0.1:8787/health)
- [admin](http://127.0.0.1:8787/admin)

## 3. 配置签名

仓库已经提交：

- [Signing.xcconfig](/Users/peiel/Project/cloud-placeholders/macos/Config/Signing.xcconfig)
- [Build.xcconfig](/Users/peiel/Project/cloud-placeholders/macos/Config/EnterpriseCloudDriveApp/Build.xcconfig)
- [Build.xcconfig](/Users/peiel/Project/cloud-placeholders/macos/Config/EnterpriseCloudDriveFileProvider/Build.xcconfig)
- [Signing.local.xcconfig.example](/Users/peiel/Project/cloud-placeholders/macos/Config/Signing.local.xcconfig.example)

本机步骤：

1. 复制 `Signing.local.xcconfig.example` 为 `macos/Config/Signing.local.xcconfig`
2. 把 `CLOUDDRIVE_DEVELOPMENT_TEAM` 改成你的付费 Apple Developer Team ID
3. 如有需要，覆盖 `CLOUDDRIVE_CODE_SIGN_IDENTITY`
4. 在 Apple Developer 后台为 App 和 appex 使用同一 Team、同一 App Group capability

要求：

- 必须是支持 `App Groups` 的付费 Apple Developer Team
- App 与 File Provider Extension 必须共享同一个 App Group
- 两边 entitlements 都已经包含 `com.apple.security.files.bookmarks.app-scope`
- App 额外保留 `com.apple.security.files.user-selected.read-write`

## 4. 构建 signed Debug 包

```bash
cd /Users/peiel/Project/cloud-placeholders/macos
xcodebuild -project EnterpriseCloudDrive.xcodeproj -scheme EnterpriseCloudDrive -configuration Debug build
```

如果 `Signing.local.xcconfig` 配置正确，这一步会走签名构建，不再需要 `CODE_SIGNING_ALLOWED=NO`。

## 5. 启动菜单栏 App

构建产物通常位于：

`~/Library/Developer/Xcode/DerivedData/EnterpriseCloudDrive-*/Build/Products/Debug/EnterpriseCloudDrive.app`

启动后先进入 Settings。

## 6. 选择后端

### 模式 A：Mock Server

- Backend 选择 `Mock Server`
- 填写 `Mock Server URL`
- 点击“保存配置”
- 点击“注册 File Provider Domain”

### 模式 B：Local Directory

- Backend 选择 `Local Directory`
- 点击“选择目录”
- 选择一个本地目录或外接盘目录
- 确认状态变成“已授权”
- 点击“保存配置”
- 点击“注册 File Provider Domain”

## 7. 验证共享容器

菜单栏中可直接点击“打开共享数据目录”。

目录下会出现：

- `state.sqlite`
- `cache/`
- `staging/`
- `sync.lock`

如果使用本地目录后端，`state.sqlite` 里还会出现：

- `source_entries`
- `provider_changes`

## 8. Finder 验证清单

至少验证以下路径：

1. App 启动并注册 domain 后，不手动点“立即同步”，Finder 也能看到首屏目录树
2. 双击云端文件时，Extension 能按需 materialize 到 `cache/`
3. 在 Finder 中新建文件 / 目录、改名、移动、删除，源目录能被同步回写
4. 在源目录外部直接修改内容，菜单栏 App 的 watcher 能触发 debounce 同步，并把变化推回 Finder
5. 拔出外接盘或让 bookmark 失效后，Finder 中已有树结构不会被清空；App 会显示目录不可用错误

## 9. 已知边界

- watcher 目前驻留在菜单栏 App，不在 Extension 内长驻
- 本阶段没有 PushKit，也没有独立 daemon
- 如果没有有效签名，Finder 中的 File Provider 行为不能作为验收结果
