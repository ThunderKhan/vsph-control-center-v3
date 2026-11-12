import { describe, expect, it, vi } from 'vitest';
import { hashSessionToken } from './session-tokens.js';
import { loginPortal, PortalLoginError, type PortalLoginDependencies } from './portal-login.js';

const userId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const token = 'the-replaced-opaque-token-from-an-isolated-test';
const profile = {
  id: userId,
  full_name: 'Example Employee',
  email: 'employee@example.test',
  platform_role: 'employee',
  status: 'active',
};
function setup(overrides: {
  profile?: typeof profile | null;
  verifiedUserId?: string;
  temporaryAllowed?: boolean;
  enrollment?: string;
} = {}) {
  const store = {
    findActiveProfile: vi.fn(async () => overrides.profile === undefined ? profile : overrides.profile),
    createPortalSession: vi.fn(async (_record: unknown) => {}),
    logoutTemporary: vi.fn(async (_raw?: string) => {}),
    tryTemporaryLogin: vi.fn(async (_input: unknown) => overrides.temporaryAllowed ?? false),
  };
  const verifyIdentity = vi.fn(async (_credentials: unknown) => ({
    user: {
      id: overrides.verifiedUserId ?? userId,
      email: profile.email,
      app_metadata: {
        ...(overrides.enrollment ? { vsph_employee_enrollment: overrides.enrollment } : {}),
      },
    },
    assurance: 'aal1' as const,
  }));
  const deps: PortalLoginDependencies = {
    store, verifyIdentity,
    now: () => Date.parse('2026-11-12T00:00:00Z'),
    token: () => token,
  };
  return { deps, store, verifyIdentity };
}
describe('original portal login orchestration', () => {
  it('issues a hashed four-hour portal session only after an active matched profile', async () => {
    const { deps, store, verifyIdentity } = setup();
    const result = await loginPortal(
      { email: ' EMPLOYEE@EXAMPLE.TEST ', password: ' secret ' },
      { 'vsph.employee.setup': 'old-setup' },
      deps,
    );
    expect(verifyIdentity).toHaveBeenCalledWith({
      email: 'employee@example.test', password: ' secret ',
      totpCode: undefined, totpFactorId: undefined,
    });
    expect(store.logoutTemporary).toHaveBeenCalledWith('old-setup');
    expect(store.createPortalSession).toHaveBeenCalledWith({
      token_hash: hashSessionToken(token),
      user_id: userId,
      expires_at: '2026-11-12T04:00:00.000Z',
    });
    expect(result).toMatchObject({
      response: { message: 'Signed in.', user: {
        id: userId, name: 'Example Employee', email: profile.email, platformRole: 'employee',
      } },
      cookies: [
        { action: 'clear', name: 'vsph.employee.setup' },
        { action: 'set', name: 'vsph.portal.sid', value: token, maxAgeMs: 14400000 },
      ],
    });
  });

  it('rejects missing credentials before asking the Auth provider to sign in', async () => {
    const { deps, verifyIdentity } = setup();
    await expect(loginPortal({ email: '', password: 'secret' }, {}, deps))
      .rejects.toMatchObject({ status: 400, message: 'Email and password are required.' });
    expect(verifyIdentity).not.toHaveBeenCalled();
    expect(new PortalLoginError(403, 'Denied')).toBeInstanceOf(Error);
  });

  it('rejects disabled or missing profiles, with no portal session created', async () => {
    for (const profileOverride of [null, { ...profile, status: 'disabled' }]) {
      const { deps, store } = setup({ profile: profileOverride });
      await expect(loginPortal({ email: profile.email, password: 'secret' }, {}, deps))
        .rejects.toMatchObject({ status: 403 });
      expect(store.createPortalSession).not.toHaveBeenCalled();
      expect(store.tryTemporaryLogin).not.toHaveBeenCalled();
    }
  });

  it('rejects mismatched provider identity instead of authorizing a different account', async () => {
    const { deps, store } = setup({ verifiedUserId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' });
    await expect(loginPortal({ email: profile.email, password: 'secret' }, {}, deps))
      .rejects.toMatchObject({ status: 403 });
    expect(store.createPortalSession).not.toHaveBeenCalled();
  });

  it('preserves the temporary employee credential handoff only through the SQL-backed gate', async () => {
    const { deps, store } = setup({ profile: null, enrollment: 'enrollment-123', temporaryAllowed: true });
    const result = await loginPortal({ email: profile.email, password: 'secret' },
      { 'vsph.crm.sid': 'old-app', 'vsph.portal.sid': 'old-portal' }, deps);
    expect(store.tryTemporaryLogin).toHaveBeenCalledWith(expect.objectContaining({
      setupHash: hashSessionToken(token),
      passwordHash: hashSessionToken('secret'),
      assurance: 'aal1',
    }));
    expect(result.response).toEqual({ passwordChangeRequired: true, redirect: '/employee-password' });
    expect(result.cookies).toContainEqual({ action: 'clear', name: 'vsph.crm.sid' });
    expect(result.cookies).toContainEqual({
      action: 'set', name: 'vsph.employee.setup', value: token, maxAgeMs: 600000,
    });
    expect(store.createPortalSession).not.toHaveBeenCalled();
  });

  it('does not issue a portal cookie when session insert fails', async () => {
    const { deps, store } = setup();
    store.createPortalSession.mockRejectedValueOnce(new Error('staging database unavailable'));
    await expect(loginPortal({ email: profile.email, password: 'secret' }, {}, deps))
      .rejects.toThrow('staging database unavailable');
  });
});
