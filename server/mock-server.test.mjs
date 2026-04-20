import test from "node:test";
import assert from "node:assert/strict";
import { applyBinaryUpload, applyDeviceRegistration, buildChangeBatch } from "./mock-server.mjs";

test("mock server state helpers track devices and uploaded items", async () => {
  const state = {
    sequence: 0,
    items: {
      root: {
        id: "root",
        parentID: null,
        name: "Enterprise Cloud Drive",
        kind: "directory",
        size: 0,
        contentHash: null,
        contentVersion: "v0",
        metadataVersion: "m0",
        remoteModifiedAt: new Date().toISOString(),
        deleted: false,
        state: "cloudOnly",
        hydrated: false,
        pinned: false,
        dirty: false,
        localPath: null,
        lastUsedAt: null,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString()
      }
    },
    changes: [],
    devices: [],
    audit: [],
    policies: {
      maxFileSizeBytes: 1,
      totalQuotaBytes: 2,
      offlineCacheLimitBytes: 3,
      allowedDeviceIDs: []
    }
  };

  const policy = applyDeviceRegistration(state, {
    tenantID: "tenant-demo",
    userID: "tester",
    deviceID: "macbook-pro",
    hostName: "macbook-pro",
    deploymentMode: "managedCloud"
  });
  assert.equal(policy.offlineCacheLimitBytes, 3);
  assert.equal(state.devices.length, 1);

  const uploadPayload = await applyBinaryUpload(state, {
    itemID: "spec",
    fileName: "spec.md",
    body: Buffer.from("hello world"),
    sha256: "abc123",
    baseContentVersion: null
  });
  assert.equal(uploadPayload.item.name, "spec.md");

  const changes = buildChangeBatch(state, null);
  assert.equal(changes.items.some(item => item.id === "spec"), true);
});
