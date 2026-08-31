# JavaScript dependency release baselines

Each `js-<release>.json` file is a machine-readable summary of the JavaScript graph and
production assets committed for that R package release. It records:

- the Node and npm toolchain used to create the baseline;
- every direct runtime and development dependency's declared and exact resolved version;
- npm integrity values for those direct packages;
- the package-lock version and package-entry count;
- SHA-256 hashes of `package.json`, `package-lock.json`, the JS bundle and stylesheet, and
  the production `inst/www` tree (excluding local-only `bundle-stats.html`).

The snapshot is an audit index, not a replacement for the lockfile. The complete rollback contract
is the annotated Git release tag together with its `package-lock.json` and committed `inst/www`
assets. The lockfile pins all transitive packages; the committed web assets permit an immediate R
package rollback without rebuilding JavaScript.

## Reproduce or verify a tagged release

Use the exact Node and npm versions recorded in the snapshot, then run:

```bash
git checkout <release-tag>
npm ci
npm run dependencies:check
```

Use `npm ci`, not `npm install`: several declarations intentionally use semver ranges or `latest`,
while the tagged lockfile records the exact tested graph. Rebuilding is optional because the tagged
`inst/www` assets are already production-ready. If rebuilding is required:

```bash
npm ci
npm run build
npm run dependencies:check
```

## Update after an intentional dependency or production-asset change

```bash
npm run build
npm run dependencies:snapshot
npm run test:dependencies
npm run dependencies:check
```

Review the JSON diff before committing it. The generator performs no network access and writes only
when invoked through `dependencies:snapshot`.
