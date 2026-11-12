import { describe, expect, it, vi } from 'vitest';
import { buildApp } from '../../app.js';
import { IdentityError } from './credentials.js';
import { hashSessionToken } from './session-tokens.js';
import type { PortalLoginDependencies } from './portal-login.js';

const userId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const token = 'a'.repeat(43);
function setup(overrides: { profileActive?: boolean; verified?: boolean } = {}) {
  const store = {
    findActiveProfile: vi.fn(async () => overrides.profileActive === false ? null : ({
      id: userId, full_name: 'Example Employee', email: 'employee@example.test',
      platform_role: 'employee', status: 'active',
    })),
    createPortalSession: vi.fn(async (_record: unknown) => {}),
    logoutTemporary: vi.fn(async (_cookie: string | undefined) => {}),
    tryTemporaryLogin: vi.fn(async (_input: unknown) => false),
  };
  const verifyIdentity = vi.fn(async (_body: unknown) => {
    if (overrides.verified === false) {
      throw new IdentityError(401, 'INVALID_CREDENTIALS', 'Invalid credentials or email not confirmed.');
    }
    return {
      user: { id: userId, email: 'employee@example.test' },
      assurance: 'aal1' as const,
    };
  });
  const login: PortalLoginDependencies = {
    verifyIdentity, store, token: () => token,
    now: () => Date.parse('2026-11-12T00:00:00Z'),
  };
  return { login, store, verifyIdentity };
}
const payload = { email: 'employee@example.test', password: 'not-a-real-password' };
const headers = { origin: 'http://localhost:3000' };

describe('optional Fastify portal-login contract', () => {
  it('fails closed by default without an approved store adapter', async () => {
    const app = buildApp();
    try {
      const result = await app.inject({
        method: 'POST', url: '/api/auth/login', headers, payload,
      });
      expect(result.statusCode).toBe(503);
      expect(result.headers['set-cookie']).toBeUndefined();
    } finally { await app.close(); }
  });

  it('with an injected fake creates session before issuing secure cookie instructions', async () => {
    const { login, store } = setup();
    const app = buildApp({ login });
    try {
      const result = await app.inject({
        method: 'POST', url: '/api/auth/login', headers, payload,
      });
      expect(result.statusCode).toBe(200);
      expect(result.json()).toMatchObject({
        message: 'Signed in.', user: { id: userId, name: 'Example Employee' },
      });
      expect(store.createPortalSession).toHaveBeenCalledWith(expect.objectContaining({
        token_hash: hashSessionToken(token),
        user_id: userId,
      }));
      const setCookies = result.headers['set-cookie'];
      expect(JSON.stringify(setCookies)).toContain('vsph.portal.sid=' + token);
      expect(JSON.stringify(setCookies)).toContain('HttpOnly');
      expect(JSON.stringify(setCookies)).toContain('SameSite=Lax');
      expect(JSON.stringify(setCookies)).toContain('Max-Age=14400');
    } finally { await app.close(); }
  });

  it('rejects missing Origin before attempting provider verification', async () => {
    const { login, verifyIdentity } = setup();
    const app = buildApp({ login });
    try {
      const result = await app.inject({ method: 'POST', url: '/api/auth/login', payload });
      expect(result.statusCode).toBe(403);
      expect(verifyIdentity).not.toHaveBeenCalled();
    } finally { await app.close(); }
  });

  it('does not set a session cookie for disabled users or rejected credentials', async () => {
    for (const override of [{ profileActive: false }, { verified: false }]) {
      const { login, store } = setup(override);
      const app = buildApp({ login });
      try {
        const result = await app.inject({
          method: 'POST', url: '/api/auth/login', headers, payload,
        });
        expect([401, 403]).toContain(result.statusCode);
        expect(result.headers['set-cookie']).toBeUndefined();
        expect(store.createPortalSession).not.toHaveBeenCalled();
      } finally { await app.close(); }
    }
  });

  it('returns 503 and no cookie when the synthetic database insert fails', async () => {
    const { login, store } = setup();
    store.createPortalSession.mockRejectedValueOnce(new Error('never report to clients'));
    const app = buildApp({ login });
    try {
      const result = await app.inject({
        method: 'POST', url: '/api/auth/login', headers, payload,
      });
      expect(result.statusCode).toBe(503);
      expect(result.headers['set-cookie']).toBeUndefined();
      expect(result.json().message).not.toContain('never report to clients');
    } finally { await app.close(); }
  });
});
