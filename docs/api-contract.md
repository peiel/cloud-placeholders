# Mock API Contract

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

返回自某个游标之后的增量变更；如果未传 `cursor`，则返回完整当前快照。

## Metadata Plane

### `GET /api/items/:id`

返回单个文件元数据。

### `GET /api/items?parentId=root`

返回某目录下的子项。

### `PATCH /api/items/:id`

更新文件名或父目录。

### `DELETE /api/items/:id`

将文件标记为删除并写入变更流。

## Data Plane

### `GET /api/items/:id/content`

下载对象内容，支持 `Range`。

### `POST /api/items/:id/content?name=<fileName>`

上传对象内容并原子提交新版本。

请求头：

- `X-Content-SHA256`
- `X-Base-Content-Version`
- `X-Base-Metadata-Version`

冲突时返回 `409`。

## Admin

### `GET /api/admin/devices`

设备注册列表。

### `GET /api/admin/items`

当前未删除元数据列表。

### `GET /api/admin/audit`

审计日志。
