import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';

const fixtures = [
  ['frontend/public/fonts/inter-5a8d3e72.woff2', '5a8d3e72ad7ffb62af3b146e1b1f54ab5813a212'],
  ['docs/reference/screenshots/login-desktop.jpg', '6688df4f96152b0d4156980ded319b8bf055ee42'],
  ['docs/reference/screenshots/login-mobile.jpg', '5f6ed5fc272bba69ff72e39fcc581545d898aa77'],
];
const root = new URL('../', import.meta.url);

function gitBlobSha(bytes) {
  return createHash('sha1')
    .update(Buffer.from('blob ' + bytes.length + '\0'))
    .update(bytes)
    .digest('hex');
}

test('preserve exact legacy assets (including font and screenshots)', async () => {
  for (const [path, expectedSha] of fixtures) {
    const binary = await readFile(new URL(path, root));
    assert.equal(gitBlobSha(binary), expectedSha, 'legacy blob mismatch: ' + path);
  }
});

test('CSS references original bundled Inter font; license retained', async () => {
  const [css, fonts, license] = await Promise.all([
    readFile(new URL('frontend/src/app/auth.css', root), 'utf8'),
    readFile(new URL('frontend/public/fonts.css', root), 'utf8'),
    readFile(new URL('docs/reference/fonts/INTER-LICENSE.txt', root), 'utf8'),
  ]);
  assert.match(css, /@import url\('\/fonts\.css'\)/);
  assert.match(fonts, /inter-5a8d3e72\.woff2/);
  assert.match(license, /SIL OPEN FONT LICENSE/i);
});
