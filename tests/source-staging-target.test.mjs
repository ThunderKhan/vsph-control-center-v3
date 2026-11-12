import { test } from 'node:test';
import assert from 'node:assert/strict';
import { stagingDirectUrl } from '../scripts/staging-target.mjs';

const base = {
  DIRECT_URL: 'postgresql://readonly:secret@127.0.0.1:5432/isolated_staging',
  STAGING_INSPECTION_APPROVED: 'true',
  STAGING_RESTORE_VERIFIED: 'true',
  STAGING_DATABASE_HOST: '127.0.0.1',
  STAGING_DATABASE_NAME: 'isolated_staging',
  STAGING_READ_ONLY_ROLE: 'readonly',
};

test('Prisma generation without a DB URL can run offline', () => {
  assert.equal(stagingDirectUrl({}), '');
});

test('staging inspection requires explicit approval and actual restore acknowledgement', () => {
  assert.equal(stagingDirectUrl(base), base.DIRECT_URL);
  for (const key of [
    'STAGING_INSPECTION_APPROVED', 'STAGING_RESTORE_VERIFIED',
    'STAGING_DATABASE_HOST', 'STAGING_DATABASE_NAME', 'STAGING_READ_ONLY_ROLE',
  ]) {
    const bad = { ...base };
    delete bad[key];
    assert.throws(() => stagingDirectUrl(bad));
  }
});

test('rejects host/name/SQL role mismatch, remote TLS downgrade and URL overrides', () => {
  assert.throws(() => stagingDirectUrl({
    ...base, DIRECT_URL: base.DIRECT_URL.replace('isolated_staging', 'production'),
  }));
  assert.throws(() => stagingDirectUrl({
    ...base, DIRECT_URL: base.DIRECT_URL.replace('readonly:', 'postgres:'),
  }));
  assert.throws(() => stagingDirectUrl({
    ...base, DIRECT_URL: base.DIRECT_URL + '?host=production-db.example.test',
  }));
  assert.throws(() => stagingDirectUrl({
    ...base, DIRECT_URL: base.DIRECT_URL + '#override',
  }));
  const remote = {
    ...base,
    DIRECT_URL: 'postgresql://readonly:secret@db.staging.example.test:5432/isolated_staging?sslmode=disable',
    STAGING_DATABASE_HOST: 'db.staging.example.test',
  };
  assert.throws(() => stagingDirectUrl(remote));
  assert.equal(stagingDirectUrl({
    ...remote, DIRECT_URL: remote.DIRECT_URL.replace('sslmode=disable', 'sslmode=verify-full'),
  }), remote.DIRECT_URL.replace('sslmode=disable', 'sslmode=verify-full'));
  assert.throws(() => stagingDirectUrl({ ...base, PRODUCTION_DATABASE_HOST: '127.0.0.1' }));
});
