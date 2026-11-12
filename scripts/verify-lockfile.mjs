/**
 * Fail with a clear actionable message before any networked CI build.
 * Do not generate or handcraft a dependency lockfile without npm resolution.
 */
import { readFile } from 'node:fs/promises';
import { URL } from 'node:url';

const root = new URL('../', import.meta.url);
let lock;
try {
  lock = JSON.parse(await readFile(new URL('package-lock.json', root), 'utf8'));
} catch {
  console.error('Missing or unreadable root package-lock.json. On Node 24 with npm access run: npm install --package-lock-only, review the changes, then commit it.');
  process.exit(1);
}

const pkg = JSON.parse(await readFile(new URL('package.json', root), 'utf8'));
if (lock.lockfileVersion < 3 ||
    lock.name !== pkg.name ||
    !lock.packages ||
    !lock.packages[''] ||
    !Array.isArray(pkg.workspaces)) {
  console.error('Root package-lock.json is not a valid npm v3 workspace lockfile.');
  process.exit(1);
}
for (const path of pkg.workspaces) {
  if (!lock.packages[path]) {
    console.error('Lockfile missing workspace package: ' + path);
    process.exit(1);
  }
}
console.log('Root npm workspace lockfile structure is present. npm ci will verify full integrity.');
