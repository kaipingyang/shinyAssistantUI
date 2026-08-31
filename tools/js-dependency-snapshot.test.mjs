import assert from "node:assert/strict";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import test from "node:test";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  createSnapshot,
  createWebAssetTree,
  dependencySnapshotPath,
  verifySnapshot,
} from "./js-dependency-snapshot.mjs";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

test("the release JavaScript dependency snapshot matches manifests and web assets", () => {
  const actual = createSnapshot(repositoryRoot);
  const expected = JSON.parse(readFileSync(dependencySnapshotPath(repositoryRoot), "utf8"));

  assert.deepEqual(actual, expected);
  assert.deepEqual(verifySnapshot(repositoryRoot), { ok: true, differences: [] });
});

test("the snapshot records every direct dependency with an exact resolved artifact", () => {
  const packageJson = JSON.parse(readFileSync(resolve(repositoryRoot, "package.json"), "utf8"));
  const snapshot = createSnapshot(repositoryRoot);

  assert.deepEqual(
    Object.keys(snapshot.dependencies),
    Object.keys(packageJson.dependencies).sort(),
  );
  assert.deepEqual(
    Object.keys(snapshot.devDependencies),
    Object.keys(packageJson.devDependencies).sort(),
  );

  for (const section of [snapshot.dependencies, snapshot.devDependencies]) {
    for (const dependency of Object.values(section)) {
      assert.match(dependency.resolved, /^\d+\.\d+\.\d+/);
      assert.match(dependency.integrity, /^sha(256|512)-/);
    }
  }

  assert.equal(snapshot.lockfile.version, 3);
  assert.ok(snapshot.lockfile.packageEntries > 500);
  assert.ok(snapshot.artifacts.webAssetFiles > 1);
  assert.match(snapshot.artifacts.bundleSha256, /^[a-f0-9]{64}$/);
  assert.match(snapshot.artifacts.stylesheetSha256, /^[a-f0-9]{64}$/);
  assert.match(snapshot.artifacts.webAssetTreeSha256, /^[a-f0-9]{64}$/);
});

test("the web asset snapshot rejects symbolic links instead of following them", () => {
  const repositoryRoot = mkdtempSync(resolve(tmpdir(), "shinyAssistantUI-snapshot-"));
  try {
    const webRoot = resolve(repositoryRoot, "inst", "www");
    mkdirSync(webRoot, { recursive: true });
    const outside = resolve(repositoryRoot, "outside.txt");
    writeFileSync(outside, "outside web root\n");
    symlinkSync(outside, resolve(webRoot, "escape.txt"));

    assert.throws(
      () => createWebAssetTree(repositoryRoot),
      /symbolic link/i,
    );
  } finally {
    rmSync(repositoryRoot, { recursive: true, force: true });
  }
});
