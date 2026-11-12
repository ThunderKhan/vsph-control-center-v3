import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, access } from 'node:fs/promises';
import { URL } from 'node:url';

const root = new URL('../', import.meta.url);
const read = (relative) => readFile(new URL(relative, root), 'utf8');
const json = async (relative) => JSON.parse(await read(relative));

test('v3 is one independent npm-workspace repository with separate frontend/backend/docs', async () => {
  const pkg = await json('package.json');
  assert.equal(pkg.private, true);
  assert.deepEqual([...pkg.workspaces].sort(), ['backend', 'frontend', 'shared', 'workers']);
  for (const name of ['frontend', 'backend', 'shared', 'workers']) {
    assert.equal((await json(name + '/package.json')).private, true);
  }
  await access(new URL('docs/migration/PARITY_REQUIREMENTS.md', root));
  await access(new URL('docs/migration/LEGACY_BASELINE.md', root));
});

test('Next.js and Fastify remain separate and reflect the approved stack', async () => {
  const web = await json('frontend/package.json');
  const api = await json('backend/package.json');
  assert.ok(web.dependencies.next, 'Next.js must be installed');
  assert.ok(web.dependencies.react, 'React must be installed');
  assert.ok(web.dependencies['react-dom'], 'React DOM must be installed');
  assert.ok(api.dependencies.fastify, 'Fastify must be installed');
  assert.ok(api.dependencies['@supabase/supabase-js'], 'Supabase Auth integration required');
  assert.equal(api.dependencies['@prisma/client'], api.devDependencies.prisma);
  assert.equal(api.dependencies['@prisma/adapter-pg'], api.devDependencies.prisma);
  assert.equal(web.dependencies.express, undefined);
  assert.equal(api.dependencies.express, undefined);
  assert.equal(web.dependencies.vite, undefined);
});

test('production auth remains fail-closed until explicitly gated integration is reviewed', async () => {
  const app = await read('backend/src/app.ts');
  const prisma = await read('backend/prisma/schema.prisma');
  assert.match(app, /\/api\/auth\/login/);
  assert.match(app, /reply\.code\(503\)/);
  assert.match(prisma, /provider\s*=\s*"postgresql"/);
  assert.doesNotMatch(await read('package.json'), /prisma migrate deploy/);
});

test('original CSS remains part of the migrated login, not a visual redesign', async () => {
  const layout = await read('frontend/src/app/layout.tsx');
  assert.match(layout, /import '\.\/auth\.css'/);
  assert.match(layout, /import '\.\/crm-auth\.css'/);
  assert.match(await read('frontend/src/app/login/page.tsx'), /AuthPage/);
});
