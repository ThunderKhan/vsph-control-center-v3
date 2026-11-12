import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { URL } from 'node:url';

const root = new URL('../', import.meta.url);
const load = async (path) => readFile(new URL(path, root), 'utf8');

test('original sign-in CSS is preserved byte-for-byte in Next.js', async () => {
  for (const name of ['auth.css', 'crm-auth.css']) {
    const reference = await load('docs/reference/styles/' + name);
    const port = await load('frontend/src/app/' + name);
    assert.equal(port, reference, name + ' is not equal to frozen source');
  }
});

test('legacy HTML and controller evidence exists for traceability', async () => {
  const html = await load('docs/reference/views/auth.html');
  const controller = await load('docs/reference/scripts/auth-page.js');
  assert.match(html, /id="authForm"/);
  assert.match(html, /id="mfaField"/);
  assert.match(html, /id="inviteEntry"/);
  assert.match(controller, /MFA_REQUIRED/);
  assert.match(controller, /\/api\/auth\/app-login/);
  assert.match(controller, /passwordChangeRequired/);
});

test('login copy and DOM identifiers retain the legacy anchors', async () => {
  const html = await load('docs/reference/views/auth.html');
  const tsx = await load('frontend/src/features/auth/AuthPage.tsx');
  const copy = await load('frontend/src/features/auth/presentation.ts');
  for (const id of ['authForm','authSubmit','authHeading','heroKicker','heroLineOne',
    'heroLineTwo','heroDescription','cardKicker','formDescription','email','password',
    'organizationField','organizationId','mfaField','totpCode','mfaFactorField',
    'totpFactorId','authError','inviteEntry','backLink']) {
    assert.ok(html.includes('id="' + id + '"'), 'legacy missing ' + id);
    assert.ok(tsx.includes('id="' + id + '"'), 'new screen missing ' + id);
  }
  for (const snippet of ['ENTERPRISE SOFTWARE', 'Building', "What's Next",
    'VSPH CONTROL CENTER', 'Welcome back',
    'Sign in to access your organization’s applications.']) {
    assert.ok(html.includes(snippet), 'legacy missing ' + snippet);
    assert.ok(copy.includes(snippet), 'new copy missing ' + snippet);
  }
});

test('backend remains fail-closed until authentication is ported', async () => {
  const app = await load('backend/src/app.ts');
  assert.match(app, /app\.post\('\/api\/auth\/login'/);
  assert.match(app, /reply\.code\(503\)/);
});
