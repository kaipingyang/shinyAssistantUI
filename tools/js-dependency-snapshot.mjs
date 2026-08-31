import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  writeFileSync,
} from "node:fs";
import { dirname, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const SNAPSHOT_SCHEMA_VERSION = 1;
const EXCLUDED_WEB_ASSETS = new Set(["bundle-stats.html"]);

const sha256 = (value) => createHash("sha256").update(value).digest("hex");
const fileSha256 = (path) => sha256(readFileSync(path));
const readJson = (path) => JSON.parse(readFileSync(path, "utf8"));

const compareText = (left, right) => (left < right ? -1 : left > right ? 1 : 0);
const sortedObject = (entries) => Object.fromEntries(
  [...entries].sort(([left], [right]) => compareText(left, right)),
);

function packageVersion(repositoryRoot) {
  const description = readFileSync(resolve(repositoryRoot, "DESCRIPTION"), "utf8");
  const match = description.match(/^Version:\s*(\d+\.\d+\.\d+)\s*$/m);
  if (!match) throw new Error("DESCRIPTION must contain a three-part Version field");
  return match[1];
}

function npmVersion() {
  const userAgent = process.env.npm_config_user_agent ?? "";
  const match = userAgent.match(/(?:^|\s)npm\/([^\s]+)/);
  if (match) return match[1];

  const executable = process.platform === "win32" ? "npm.cmd" : "npm";
  return execFileSync(executable, ["--version"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  }).trim();
}

function directDependencies(declared, lockfile) {
  const entries = Object.entries(declared ?? {}).map(([name, requested]) => {
    const locked = lockfile.packages?.[`node_modules/${name}`];
    if (!locked?.version) throw new Error(`package-lock.json is missing ${name}`);
    if (!locked.integrity) throw new Error(`package-lock.json has no integrity for ${name}`);
    return [name, {
      declared: requested,
      resolved: locked.version,
      integrity: locked.integrity,
    }];
  });
  return sortedObject(entries);
}

function webAssetFiles(repositoryRoot) {
  const webRoot = resolve(repositoryRoot, "inst", "www");
  const files = [];
  const visit = (directory) => {
    for (const entry of readdirSync(directory).sort()) {
      const path = resolve(directory, entry);
      const name = relative(webRoot, path).split(sep).join("/");
      const metadata = lstatSync(path);
      if (metadata.isSymbolicLink()) {
        throw new Error(`Refusing symbolic link in inst/www: ${name}`);
      }
      if (metadata.isDirectory()) {
        visit(path);
        continue;
      }
      if (!EXCLUDED_WEB_ASSETS.has(name)) files.push({ name, path });
    }
  };
  visit(webRoot);
  return files;
}

export function createWebAssetTree(repositoryRoot) {
  const files = webAssetFiles(repositoryRoot);
  const manifest = files
    .map(({ name, path }) => `${name}\0${fileSha256(path)}`)
    .join("\n");
  return {
    files: files.length,
    sha256: sha256(`${manifest}\n`),
  };
}

export function dependencySnapshotPath(repositoryRoot) {
  return resolve(
    repositoryRoot,
    "dependency-snapshots",
    `js-${packageVersion(repositoryRoot)}.json`,
  );
}

export function createSnapshot(repositoryRoot) {
  const packageJsonPath = resolve(repositoryRoot, "package.json");
  const packageLockPath = resolve(repositoryRoot, "package-lock.json");
  const packageJson = readJson(packageJsonPath);
  const lockfile = readJson(packageLockPath);
  const webAssets = createWebAssetTree(repositoryRoot);

  if (lockfile.lockfileVersion !== 3) {
    throw new Error(`Expected package-lock v3, received ${lockfile.lockfileVersion}`);
  }

  return {
    schemaVersion: SNAPSHOT_SCHEMA_VERSION,
    release: {
      package: "shinyAssistantUI",
      version: packageVersion(repositoryRoot),
    },
    toolchain: {
      node: process.version.replace(/^v/, ""),
      npm: npmVersion(),
    },
    lockfile: {
      version: lockfile.lockfileVersion,
      packageEntries: Object.keys(lockfile.packages ?? {}).length,
    },
    artifacts: {
      packageJsonSha256: fileSha256(packageJsonPath),
      packageLockSha256: fileSha256(packageLockPath),
      bundleSha256: fileSha256(resolve(repositoryRoot, "inst", "www", "shinyAssistantUI.js")),
      stylesheetSha256: fileSha256(resolve(repositoryRoot, "inst", "www", "style.css")),
      webAssetFiles: webAssets.files,
      webAssetTreeSha256: webAssets.sha256,
    },
    dependencies: directDependencies(packageJson.dependencies, lockfile),
    devDependencies: directDependencies(packageJson.devDependencies, lockfile),
  };
}

const serializedSnapshot = (snapshot) => `${JSON.stringify(snapshot, null, 2)}\n`;

export function verifySnapshot(repositoryRoot) {
  const path = dependencySnapshotPath(repositoryRoot);
  if (!existsSync(path)) {
    return { ok: false, differences: [`Missing ${relative(repositoryRoot, path)}`] };
  }

  const expected = serializedSnapshot(createSnapshot(repositoryRoot));
  const actual = readFileSync(path, "utf8");
  if (actual === expected) return { ok: true, differences: [] };
  return {
    ok: false,
    differences: [
      `${relative(repositoryRoot, path)} does not match the toolchain, package.json, package-lock.json, or inst/www`,
    ],
  };
}

function runCli() {
  const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
  const command = process.argv[2];
  const path = dependencySnapshotPath(repositoryRoot);

  if (command === "--write") {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, serializedSnapshot(createSnapshot(repositoryRoot)));
    console.log(`Wrote ${relative(repositoryRoot, path)}`);
    return;
  }

  if (command === "--check") {
    const result = verifySnapshot(repositoryRoot);
    if (result.ok) {
      console.log(`${relative(repositoryRoot, path)} is current`);
      return;
    }
    for (const difference of result.differences) console.error(difference);
    console.error("Run npm run dependencies:snapshot after reviewing intentional changes.");
    process.exitCode = 1;
    return;
  }

  console.error("Usage: node tools/js-dependency-snapshot.mjs --write|--check");
  process.exitCode = 2;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  runCli();
}
