/**
 * Frozen SQL manifest is source data ONLY; do not execute its SQL.
 * Node built-ins ensure this test runs without dependencies or DB access.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';

const root = new URL('../', import.meta.url);
const manifest = JSON.parse(await readFile(new URL('supabase/migration-manifest.json', root), 'utf8'));
const filenamePattern = /^supabase\/migrations\/[0-9]{8,14}_[a-z0-9_]+\.sql$/;
const sha256 = (buffer) => createHash('sha256').update(buffer).digest('hex');

test('preserve exact frozen SQL source (38 migrations + base schema)', async () => {
  assert.equal(manifest.format, 1);
  assert.equal(manifest.migrations.length, 38);
  assert.equal(manifest.bootstrap.path, 'supabase/schema.sql');
  const paths = [manifest.bootstrap.path, ...manifest.migrations.map((entry) => entry.path)];
  assert.equal(new Set(paths).size, paths.length, 'duplicate source file');
  for (const entry of [manifest.bootstrap, ...manifest.migrations]) {
    assert.ok(entry.path === manifest.bootstrap.path || filenamePattern.test(entry.path),
      'unexpected SQL source path: ' + entry.path);
    assert.match(entry.sha256, /^[a-f0-9]{64}$/i);
    const bytes = await readFile(new URL(entry.path, root));
    assert.equal(sha256(bytes), entry.sha256, 'source SQL checksum drift: ' + entry.path);
  }
  const existing = (await readdir(new URL('supabase/migrations/', root))).sort();
  const expected = manifest.migrations.map((entry) => entry.path.split('/').at(-1)).sort();
  assert.deepEqual(existing, expected, 'SQL files not declared in frozen manifest');
});

test('every migration dependency resolves to another source file without cycles', () => {
  const byPath = new Map(manifest.migrations.map((entry) => [entry.path, entry]));
  const visiting = new Set(), visited = new Set();
  function walk(path) {
    if (visited.has(path)) return;
    assert.ok(!visiting.has(path), 'migration dependency cycle: ' + path);
    visiting.add(path);
    const entry = byPath.get(path);
    assert.ok(entry, 'missing migration: ' + path);
    for (const requirement of entry.requires ?? []) {
      assert.ok(byPath.has(requirement), 'missing dependency ' + requirement);
      walk(requirement);
    }
    visiting.delete(path);
    visited.add(path);
  }
  for (const entry of manifest.migrations) walk(entry.path);
  assert.equal(visited.size, 38);
});

test('original duplicate Music migration version is preserved, not silently renumbered', () => {
  const collisions = new Map();
  for (const entry of manifest.migrations) {
    const arr = collisions.get(entry.version) ?? [];
    arr.push(entry.path);
    collisions.set(entry.version, arr);
  }
  const duplicates = [...collisions.entries()].filter(([, entries]) => entries.length > 1);
  assert.equal(duplicates.length, 1);
  assert.equal(duplicates[0][0], '20261030');
  assert.equal(duplicates[0][1].length, 2);
});
