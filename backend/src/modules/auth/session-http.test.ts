import { describe, expect, it, vi } from 'vitest';
import { buildApp } from '../../app.js';
import { hashSessionToken } from './session-tokens.js';
import type { PortalSessionStore } from './portal-session.js';

const token = 't'.repeat(43);
const user = {
  id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  full_name: 'Example Employee',
  email: 'employee@example.test',
  platform_role: 'employee',
  status: 'active',
};
const session = {
  token_hash: hashSessionToken(token),
  user_id: user.id,
  expires_at: '2099-11-12T04:00:00Z',
  profile: user,
};
const store = (row: typeof session | null): PortalSessionStore => ({
  findByTokenHash: vi.fn(async () => row),
});

describe('isolated /api/auth/me contract', () => {
  it('never returns a session with no approved backend adapter', async () => {
    const app = buildApp();
    try {
      const response = await app.inject({ method: 'GET', url: '/api/auth/me' });
      expect(response.statusCode).toBe(503);
      expect(response.json()).not.toHaveProperty('user');
    } finally { await app.close(); }
  });

  it('denies missing, expired and disabled sessions without leaking a profile', async () => {
    for (const test of [
      { row: session, cookie: undefined },
      { row: { ...session, expires_at: '2000-01-01T00:00:00Z' },
        cookie: 'vsph.portal.sid=' + token },
      { row: { ...session, profile: { ...user, status: 'disabled' } },
        cookie: 'vsph.portal.sid=' + token },
    ]) {
      const app = buildApp({ sessionStore: store(test.row) });
      try {
        const response = await app.inject({ method: 'GET', url: '/api/auth/me',
          ...(test.cookie ? { headers: { cookie: test.cookie } } : {}) });
        expect(response.statusCode).toBe(401);
        expect(response.json()).not.toHaveProperty('user');
      } finally { await app.close(); }
    }
  });

  it('returns the original bounded profile JSON only for an active session', async () => {
    const app = buildApp({ sessionStore: store(session) });
    try {
      const response = await app.inject({
        method: 'GET', url: '/api/auth/me',
        headers: { cookie: 'vsph.portal.sid=' + token },
      });
      expect(response.statusCode).toBe(200);
      expect(response.json()).toEqual({
        user: { id: user.id, name: user.full_name, email: user.email,
          platformRole: user.platform_role },
      });
      expect(response.headers['cache-control']).toBe('no-store');
    } finally { await app.close(); }
  });

  it('rejects duplicate ambiguous browser session cookies', async () => {
    const app = buildApp({ sessionStore: store(session) });
    try {
      const response = await app.inject({
        method: 'GET', url: '/api/auth/me',
        headers: { cookie: 'vsph.portal.sid=' + token + '; vsph.portal.sid=' + token },
      });
      expect(response.statusCode).toBe(401);
    } finally { await app.close(); }
  });
});
