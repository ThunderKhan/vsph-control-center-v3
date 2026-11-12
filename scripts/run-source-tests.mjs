/**
 * Cross-platform source-preservation test runner. Using explicit file paths
 * avoids shell wildcard inconsistencies on Windows cmd/PowerShell.
 * Only Node built-ins are used: no npm install or secrets required.
 */
import { readdir } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(fileURLToPath(new URL('../', import.meta.url)));
const testsDirectory = path.join(root, 'tests');
const tests = (await readdir(testsDirectory))
  .filter((name) => /^source-[a-z\d-]+\.test\.mjs$/.test(name))
  .sort()
  .map((name) => path.join(testsDirectory, name));

if (!tests.length) {
  console.error('No offline source-preservation tests were found.');
  process.exitCode = 1;
} else {
  const run = spawnSync(process.execPath, ['--test', ...tests], {
    cwd: root,
    stdio: 'inherit',
    env: process.env,
  });
  if (run.error) throw run.error;
  process.exitCode = run.status ?? 1;
}
