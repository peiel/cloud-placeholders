# 企业私有云占位符同步系统 v1

## 产品目标

打造一个面向企业知识工作者的 `macOS` 原生文件同步产品：

- Finder 中可浏览企业云盘
- 未下载文件按需拉取
- 已下载文件可释放本地空间
- 本地修改后台上传
- 企业可接入身份、策略和审计

## 本原型对应的实现范围

- 平台：`macOS`
- 部署：协议层兼容托管云与私有化
- 用户模型：企业托管下的个人工作文件
- 非目标：团队共享、多端协作、全文检索、端到端加密

## 设计落地映射

### 客户端

- `CloudPlaceholderDomain`
  - 定义 `SyncItem`、`PendingOperation`、`TransferRecord`、`DevicePolicy`
- `CloudPlaceholderPersistence`
  - 实现 `SQLiteMetadataStore`
- `CloudPlaceholderSync`
  - 实现 `SyncEngine`、`HTTPRemoteAPIClient`
- `CloudPlaceholderFileProviderKit`
  - 实现 `PlaceholderFileProviderItem`、`PlaceholderEnumerator`、`ProviderDomainController`

### 服务端

- `mock-server.mjs`
  - 设备注册
  - 变更游标
  - 元数据查询
  - 内容上传 / 下载
  - 基础审计接口
- `admin-console.html`
  - 查看设备、文件、审计

## 下一阶段建议

1. 建立 Xcode 工程，接入真实 `NSFileProviderReplicatedExtension`
2. 把 `ProviderDomainController` 接到 extension target
3. 用真实对象存储替换 `data/blob-store`
4. 用数据库替换 `server-state.json`
5. 加入推送唤醒、partial content fetching、租户身份接入
