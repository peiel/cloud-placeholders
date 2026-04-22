# Mock API Contract

这份契约只描述 `server/mock-server.mjs` 当前实现的 HTTP mock 路径。`Local Directory` 后端不走 HTTP，而是直接对源目录做扫描与回写。

## Control Plane

### `POST /api/devices/register`

注册当前设备并返回策略。

请求体：

```json
{
  "tenantID": "tenant-demo",
  "userID": "peiel",
  "deviceID": "macbook-pro",
  "hostName": "macbook-pro",
  "deploymentMode": "managedCloud"
}
```

响应体：

```json
{
  "maxFileSizeBytes": 107374182400,
  "totalQuotaBytes": 536870912000,
  "offlineCacheLimitBytes": 53687091200,
  "allowedDeviceIDs": []
}
```

### `GET /api/changes?cursor=<cursor>`

返回自某个游标之后的增量变更；如果未传 `cursor`，则返回当前全量快照。

响应体：

```json
{
  "items": [],
  "deletedItemIDs": [],
  "nextCursor": "42",
  "hasMore": false
}
```

## Metadata Plane

### `GET /api/items/:id`

返回单个文件或目录元数据。

### `GET /api/items?parentId=root`

返回某目录下的未删除子项。

### `POST /api/items/:id/directory`

创建目录。

请求体：

```json
{
  "name": "Projects",
  "parentID": "root"
}
```

响应体：

```json
{
  "item": {
    "id": "folder-1",
    "parentID": "root",
    "name": "Projects",
    "kind": "directory"
  },
  "remoteCursor": "43"
}
```

### `PATCH /api/items/:id`

更新名称或父目录，等价于重命名 / reparent。

请求体：

```json
{
  "name": "Projects-2026",
  "parentID": "root"
}
```

响应体：

```json
{
  "item": {
    "id": "folder-1",
    "parentID": "root",
    "name": "Projects-2026",
    "metadataVersion": "m44"
  },
  "remoteCursor": "44"
}
```

### `DELETE /api/items/:id`

将对象标记为删除并写入变更流。

响应体：

```json
{
  "ok": true,
  "remoteCursor": "45"
}
```

## Data Plane

### `GET /api/items/:id/content`

下载对象内容，支持 `Range`。

### `POST /api/items/:id/content?name=<fileName>&parentId=<parentID>`

上传对象内容并原子提交新版本。

请求头：

- `X-Content-SHA256`
- `X-Base-Content-Version`
- `X-Base-Metadata-Version`

冲突时返回 `409`。

响应体：

```json
{
  "item": {
    "id": "draft-1",
    "parentID": "root",
    "name": "draft.txt",
    "contentVersion": "v46",
    "metadataVersion": "m46"
  },
  "remoteCursor": "46"
}
```

## Admin

### `GET /api/admin/devices`

返回设备注册列表。

### `GET /api/admin/items`

返回当前未删除元数据列表。

### `GET /api/admin/audit`

返回审计事件列表。
