import { createHash, randomBytes } from 'node:crypto';

/** Frozen legacy tokens.js contract. Never store raw tokens in PostgreSQL. */
export const SESSION_HOURS = 4;
export const PORTAL_COOKIE = 'vsph.portal.sid';
export const EMPLOYEE_SETUP_COOKIE = 'vsph.employee.setup';

export function newSessionToken(): string {
  return randomBytes(32).toString('base64url');
}

export function hashSessionToken(raw: unknown): string {
  return createHash('sha256').update(String(raw || '')).digest('hex');
}

export function applicationCookie(code: string): string {
  return `vsph.${String(code).toLowerCase()}.sid`;
}

export function applicationCookieNames(cookies: Record<string, unknown> = {}): string[] {
  return Object.keys(cookies)
    .filter((name) =>
      /^vsph\.[a-z][a-z0-9_]{1,39}\.sid$/.test(name) &&
      name !== PORTAL_COOKIE)
    .slice(0, 100);
}

/** Same legacy httpOnly, sameSite, path, maxAge and TLS behavior. */
export function sessionCookieOptions(production: boolean) {
  return {
    httpOnly: true,
    secure: production,
    sameSite: 'lax' as const,
    path: '/',
    maxAge: SESSION_HOURS * 60 * 60 * 1000,
  };
}
