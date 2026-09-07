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

test("the snapshot path supports four-part R development versions", () => {
  const root = mkdtempSync(resolve(tmpdir(), "shinyAssistantUI-version-"));
  try {
    writeFileSync(resolve(root, "DESCRIPTION"), "Package: shinyAssistantUI\nVersion: 0.5.7.9000\n");
    assert.equal(
      dependencySnapshotPath(root),
      resolve(root, "dependency-snapshots", "js-0.5.7.9000.json"),
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("the assistant-ui core dependency set is exact and excludes A2UI", () => {
  const packageJson = JSON.parse(readFileSync(resolve(repositoryRoot, "package.json"), "utf8"));
  const snapshot = createSnapshot(repositoryRoot);
  const expectedRuntime = {
    "@assistant-ui/react": "0.15.17",
    "@assistant-ui/react-lexical": "0.2.11",
    "@assistant-ui/react-markdown": "0.14.13",
    "@lexical/react": "0.49.0",
    "@lexical/utils": "0.49.0",
    lexical: "0.49.0",
    react: "19.2.7",
    "react-dom": "19.2.7",
  };

  for (const [name, version] of Object.entries(expectedRuntime)) {
    assert.equal(snapshot.dependencies[name]?.declared, version, `${name} declared version`);
    assert.equal(snapshot.dependencies[name]?.resolved, version, `${name} resolved version`);
  }
  assert.equal(
    snapshot.devDependencies["@assistant-ui/react-devtools"]?.declared,
    "1.2.16",
  );
  assert.equal(
    snapshot.devDependencies["@assistant-ui/react-devtools"]?.resolved,
    "1.2.16",
  );

  for (const name of [
    "@assistant-ui/react-generative-ui",
    "@assistant-ui/react-ag-ui",
    "@a2ui/react",
    "@a2ui/web_core",
  ]) {
    assert.equal(packageJson.dependencies?.[name], undefined, `${name} runtime dependency`);
    assert.equal(packageJson.devDependencies?.[name], undefined, `${name} development dependency`);
  }
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
