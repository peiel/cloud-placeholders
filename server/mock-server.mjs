import crypto from "node:crypto";
import fs from "node:fs";
import fsp from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const dataRoot = path.resolve(__dirname, "../data");
const stateFile = path.join(dataRoot, "server-state.json");
const blobDirectory = path.join(dataRoot, "blob-store");

function nowISO() {
  return new Date().toISOString();
}

function defaultPolicy() {
  return {
    maxFileSizeBytes: 100 * 1024 * 1024 * 1024,
    totalQuotaBytes: 500 * 1024 * 1024 * 1024,
    offlineCacheLimitBytes: 50 * 1024 * 1024 * 1024,
    allowedDeviceIDs: []
  };
}

function makeItem(overrides = {}) {
  return {
    id: "root",
    parentID: null,
    name: "Enterprise Cloud Drive",
    kind: "directory",
    size: 0,
    contentHash: null,
    contentVersion: "v0",
    metadataVersion: "m0",
    remoteModifiedAt: nowISO(),
    deleted: false,
    state: "cloudOnly",
    hydrated: false,
    pinned: false,
    dirty: false,
    localPath: null,
    lastUsedAt: null,
    createdAt: nowISO(),
    updatedAt: nowISO(),
    ...overrides
  };
}

function defaultState() {
  return {
    sequence: 0,
    items: {
      root: makeItem()
    },
    changes: [],
    devices: [],
    audit: [],
    policies: defaultPolicy()
  };
}

async function ensureStorage() {
  await fsp.mkdir(blobDirectory, { recursive: true });
  if (!fs.existsSync(stateFile)) {
    await fsp.writeFile(stateFile, JSON.stringify(defaultState(), null, 2));
  }
}

async function loadState() {
  await ensureStorage();
  const raw = await fsp.readFile(stateFile, "utf8");
  return JSON.parse(raw);
}

async function saveState(state) {
  await ensureStorage();
  await fsp.writeFile(stateFile, JSON.stringify(state, null, 2));
}

function json(response, status, payload) {
  response.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
  response.end(JSON.stringify(payload));
}

function text(response, status, payload) {
  response.writeHead(status, { "Content-Type": "text/plain; charset=utf-8" });
  response.end(payload);
}

function parseBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    request.on("data", chunk => chunks.push(chunk));
    request.on("end", () => resolve(Buffer.concat(chunks)));
    request.on("error", reject);
  });
}

function addAudit(state, event) {
  state.audit.push({
    id: crypto.randomUUID(),
    happenedAt: nowISO(),
    ...event
  });
}

function addChange(state, item, type) {
  state.sequence += 1;
  state.changes.push({
    seq: state.sequence,
    type,
    itemID: item.id,
    item: type === "delete" ? null : item
  });
}

export function buildChangeBatch(state, cursor) {
  if (!cursor) {
    const items = Object.values(state.items).filter(item => !item.deleted && item.id !== "root");
    return {
      items,
      deletedItemIDs: [],
      nextCursor: String(state.sequence),
      hasMore: false
    };
  }

  const seq = Number(cursor);
  const changes = state.changes.filter(change => change.seq > seq);
  const upserts = new Map();
  const deleted = new Set();
  for (const change of changes) {
    if (change.type === "delete") {
      deleted.add(change.itemID);
      upserts.delete(change.itemID);
      continue;
    }
    deleted.delete(change.itemID);
    upserts.set(change.itemID, change.item);
  }
  return {
    items: [...upserts.values()],
    deletedItemIDs: [...deleted.values()],
    nextCursor: String(state.sequence),
    hasMore: false
  };
}

export function applyDeviceRegistration(state, payload) {
  state.devices = state.devices.filter(device => device.deviceID !== payload.deviceID);
  state.devices.push(payload);
  addAudit(state, {
    tenantID: payload.tenantID,
    actorID: payload.userID,
    action: "device.register",
    itemID: null,
    metadata: { hostName: payload.hostName, deploymentMode: payload.deploymentMode }
  });
  return state.policies;
}

export async function applyBinaryUpload(state, { itemID, fileName, parentID, body, sha256, baseContentVersion }) {
  const existing = state.items[itemID];
  if (existing && baseContentVersion && existing.contentVersion !== baseContentVersion) {
    throw new Error(`Version conflict: expected ${existing.contentVersion}, got ${baseContentVersion}`);
  }

  const blobPath = path.join(blobDirectory, itemID);
  await fsp.mkdir(blobDirectory, { recursive: true });
  await fsp.writeFile(blobPath, body);

  const versionNumber = state.sequence + 1;
  const item = makeItem({
    id: itemID,
    parentID: parentID || existing?.parentID || "root",
    name: fileName || existing?.name || `${itemID}.bin`,
    kind: "file",
    size: body.byteLength,
    contentHash: sha256 || crypto.createHash("sha256").update(body).digest("hex"),
    contentVersion: `v${versionNumber}`,
    metadataVersion: `m${versionNumber}`,
    remoteModifiedAt: nowISO(),
    updatedAt: nowISO(),
    createdAt: existing?.createdAt || nowISO()
  });
  state.items[itemID] = item;
  addChange(state, item, "upsert");
  addAudit(state, {
    tenantID: "tenant-demo",
    actorID: "peiel",
    action: existing ? "item.modify" : "item.create",
    itemID,
    metadata: { fileName: item.name }
  });
  return { item, remoteCursor: String(state.sequence) };
}

export function applyDirectoryCreate(state, { itemID, fileName, parentID }) {
  const versionNumber = state.sequence + 1;
  const item = makeItem({
    id: itemID,
    parentID: parentID || "root",
    name: fileName || `${itemID}`,
    kind: "directory",
    size: 0,
    contentVersion: null,
    metadataVersion: `m${versionNumber}`,
    remoteModifiedAt: nowISO(),
    updatedAt: nowISO(),
    createdAt: nowISO()
  });
  state.items[itemID] = item;
  addChange(state, item, "upsert");
  addAudit(state, {
    tenantID: "tenant-demo",
    actorID: "peiel",
    action: "item.mkdir",
    itemID,
    metadata: { fileName: item.name, parentID: item.parentID }
  });
  return { item, remoteCursor: String(state.sequence) };
}

function findRoute(url) {
  const parts = url.pathname.split("/").filter(Boolean);
  return parts;
}

function contentRange(rangeHeader, size) {
  if (!rangeHeader || !rangeHeader.startsWith("bytes=")) {
    return null;
  }
  const [startRaw, endRaw] = rangeHeader.replace("bytes=", "").split("-");
  const start = Number(startRaw);
  const end = endRaw ? Number(endRaw) : size - 1;
  if (Number.isNaN(start) || Number.isNaN(end) || start > end || end >= size) {
    return null;
  }
  return { start, end };
}

async function handleRequest(request, response) {
  const url = new URL(request.url, "http://127.0.0.1");
  const route = findRoute(url);

  if (request.method === "GET" && url.pathname === "/health") {
    return json(response, 200, { ok: true });
  }

  if (request.method === "GET" && url.pathname === "/admin") {
    const html = await fsp.readFile(path.join(__dirname, "admin-console.html"), "utf8");
    response.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    response.end(html);
    return;
  }

  const state = await loadState();

  if (request.method === "POST" && url.pathname === "/api/devices/register") {
    const payload = JSON.parse((await parseBody(request)).toString("utf8"));
    const policy = applyDeviceRegistration(state, payload);
    await saveState(state);
    return json(response, 200, policy);
  }

  if (request.method === "GET" && url.pathname === "/api/changes") {
    return json(response, 200, buildChangeBatch(state, url.searchParams.get("cursor")));
  }

  if (request.method === "GET" && route[0] === "api" && route[1] === "items" && route.length === 3) {
    const item = state.items[route[2]];
    if (!item || item.deleted) {
      return text(response, 404, "No such item");
    }
    return json(response, 200, item);
  }

  if (request.method === "GET" && url.pathname === "/api/items") {
    const parentID = url.searchParams.get("parentId") ?? "root";
    const items = Object.values(state.items)
      .filter(item => item.parentID === parentID && !item.deleted)
      .sort((left, right) => left.name.localeCompare(right.name));
    return json(response, 200, items);
  }

  if (request.method === "GET" && route[0] === "api" && route[1] === "items" && route[3] === "content") {
    const itemID = route[2];
    const item = state.items[itemID];
    if (!item || item.deleted) {
      return text(response, 404, "No such item");
    }
    const blobPath = path.join(blobDirectory, itemID);
    if (!fs.existsSync(blobPath)) {
      return text(response, 404, "No content");
    }
    const stat = await fsp.stat(blobPath);
    const range = contentRange(request.headers.range, stat.size);
    if (range) {
      response.writeHead(206, {
        "Content-Type": "application/octet-stream",
        "Content-Length": range.end - range.start + 1,
        "Content-Range": `bytes ${range.start}-${range.end}/${stat.size}`,
        "Accept-Ranges": "bytes"
      });
      fs.createReadStream(blobPath, { start: range.start, end: range.end }).pipe(response);
      return;
    }
    response.writeHead(200, {
      "Content-Type": "application/octet-stream",
      "Content-Length": stat.size,
      "Accept-Ranges": "bytes"
    });
    fs.createReadStream(blobPath).pipe(response);
    return;
  }

  if (request.method === "POST" && route[0] === "api" && route[1] === "items" && route[3] === "content") {
    const itemID = route[2];
    const body = await parseBody(request);
    try {
      const payload = await applyBinaryUpload(state, {
        itemID,
        fileName: url.searchParams.get("name"),
        parentID: url.searchParams.get("parentId"),
        body,
        sha256: request.headers["x-content-sha256"],
        baseContentVersion: request.headers["x-base-content-version"] || null
      });
      await saveState(state);
      return json(response, 200, payload);
    } catch (error) {
      return text(response, 409, error.message);
    }
  }

  if (request.method === "POST" && route[0] === "api" && route[1] === "items" && route[3] === "directory") {
    const itemID = route[2];
    const payload = JSON.parse((await parseBody(request)).toString("utf8"));
    const result = applyDirectoryCreate(state, {
      itemID,
      fileName: payload.name,
      parentID: payload.parentID
    });
    await saveState(state);
    return json(response, 200, result);
  }

  if (request.method === "PATCH" && route[0] === "api" && route[1] === "items" && route.length === 3) {
    const itemID = route[2];
    const existing = state.items[itemID];
    if (!existing || existing.deleted) {
      return text(response, 404, "No such item");
    }
    const payload = JSON.parse((await parseBody(request)).toString("utf8"));
    const versionNumber = state.sequence + 1;
    const item = {
      ...existing,
      name: payload.name ?? existing.name,
      parentID: payload.parentID ?? existing.parentID,
      metadataVersion: `m${versionNumber}`,
      updatedAt: nowISO()
    };
    state.items[itemID] = item;
    addChange(state, item, "upsert");
    addAudit(state, {
      tenantID: "tenant-demo",
      actorID: "peiel",
      action: "item.patch",
      itemID,
      metadata: payload
    });
    await saveState(state);
    return json(response, 200, { item, remoteCursor: String(state.sequence) });
  }

  if (request.method === "DELETE" && route[0] === "api" && route[1] === "items" && route.length === 3) {
    const itemID = route[2];
    const existing = state.items[itemID];
    if (!existing || existing.deleted) {
      return text(response, 404, "No such item");
    }
    state.items[itemID] = { ...existing, deleted: true, updatedAt: nowISO() };
    addChange(state, existing, "delete");
    addAudit(state, {
      tenantID: "tenant-demo",
      actorID: "peiel",
      action: "item.delete",
      itemID,
      metadata: {}
    });
    await saveState(state);
    return json(response, 200, { ok: true, remoteCursor: String(state.sequence) });
  }

  if (request.method === "GET" && url.pathname === "/api/admin/devices") {
    return json(response, 200, state.devices);
  }

  if (request.method === "GET" && url.pathname === "/api/admin/items") {
    return json(response, 200, Object.values(state.items).filter(item => !item.deleted));
  }

  if (request.method === "GET" && url.pathname === "/api/admin/audit") {
    return json(response, 200, state.audit);
  }

  return text(response, 404, "Not found");
}

export function createServer() {
  return http.createServer((request, response) => {
    handleRequest(request, response).catch(error => {
      console.error(error);
      text(response, 500, error.stack || String(error));
    });
  });
}

if (process.argv[1] === __filename) {
  const server = createServer();
  const port = Number(process.env.PORT || 8787);
  server.listen(port, "127.0.0.1", () => {
    console.log(`Mock server listening on http://127.0.0.1:${port}`);
  });
}
