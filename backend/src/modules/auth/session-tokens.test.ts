import { describe, expect, it } from 'vitest';
import {
  newSessionToken, hashSessionToken, sessionCookieOptions,
  applicationCookieNames, applicationCookie, PORTAL_COOKIE,
} from './session-tokens.js';

describe('original opaque session invariants', () => {
  it('generates 32-byte opaque tokens, stores only SHA256', () => {
    const a = newSessionToken();
    const b = newSessionToken();
    expect(a).not.toBe(b);
    expect(Buffer.from(a, 'base64url')).toHaveLength(32);
    expect(hashSessionToken(a)).toMatch(/^[a-f\d]{64}$/);
    expect(hashSessionToken(a)).not.toContain(a);
  });

  it('retains original cookie attributes', () => {
    expect(sessionCookieOptions(true)).toEqual({
      httpOnly: true, secure: true, sameSite: 'lax',
      path: '/', maxAge: 4 * 3600 * 1000,
    });
    expect(sessionCookieOptions(false).secure).toBe(false);
    expect(applicationCookie('MUSIC')).toBe('vsph.music.sid');
    expect(PORTAL_COOKIE).toBe('vsph.portal.sid');
  });

  it('only enumerates valid application session cookies', () => {
    expect(applicationCookieNames({
      'vsph.crm.sid': 'a',
      'vsph.music.sid': 'b',
      'vsph.portal.sid': 'c',
      'vsph.employee.setup': 'd',
      'evil.sid': 'e',
    })).toEqual(['vsph.crm.sid', 'vsph.music.sid']);
  });
});
