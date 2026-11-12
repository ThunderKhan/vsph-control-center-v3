import { hashSessionToken, newSessionToken, SESSION_HOURS, applicationCookieNames } from './session-tokens.js';
import type { PortalProfile } from './portal-session.js';
import type { ProviderUser } from './identity-provider.js';

/** The cookie instructions are data; only the HTTP adapter may emit Set-Cookie. */
export type CookieInstruction =
  | { action: 'set'; name: string; value: string; maxAgeMs: number }
  | { action: 'clear'; name: string };

export type LoginIdentity = {
  user: ProviderUser;
  assurance: 'aal1' | 'aal2';
};

export type PortalLoginStore = {
  /** Must query the original active profiles table; disabled accounts are denied. */
  findActiveProfile(userId: string): Promise<PortalProfile | null>;
  /** Must issue one atomic INSERT with hashed token; never store the raw secret. */
  createPortalSession(record: {
    token_hash: string;
    user_id: string;
    expires_at: string;
  }): Promise<void>;
  /** Must execute the original `internal_employee_credentials` logout RPC. */
  logoutTemporary(raw: string | undefined): Promise<void>;
  /**
   * Must use the original SQL temporary-credential login RPC, with its
   * enrollment/expiry/nonce protections. No fake local fallback is permitted.
   */
  tryTemporaryLogin(input: {
    user: ProviderUser;
    assurance: 'aal1' | 'aal2';
    setupHash: string;
    passwordHash: string;
  }): Promise<boolean>;
};

export type PortalLoginDependencies = {
  verifyIdentity: (credentials: unknown) => Promise<LoginIdentity>;
  store: PortalLoginStore;
  now?: () => number;
  token?: () => string;
};

/**
 * Source-equivalent portal login transaction orchestration from
 * legacy routes/auth.js (frozen SHA 3b3a1535873aa0517aea41da32a407f3d9680547).
 *
 * This service cannot operate on production: there is no SQL/Prisma adapter
 * wired into the Fastify server, and live HTTP login remains a 503 stub.
 */
export async function loginPortal(
  body: unknown,
  cookies: Record<string, string | undefined>,
  deps: PortalLoginDependencies,
): Promise<{
  response: {
    message?: string;
    passwordChangeRequired?: boolean;
    redirect?: string;
    user?: { id: string; name: string; email: string; platformRole: string | null };
  };
  cookies: CookieInstruction[];
}> {
  const fields = body && typeof body === 'object' && !Array.isArray(body)
    ? body as Record<string, unknown> : {};
  const email = String(fields.email || '').trim().toLowerCase();
  const password = String(fields.password || '');
  if (!email || !password) {
    // The legacy HTTP route performs this check before contacting Supabase.
    throw new PortalLoginError(400, 'Email and password are required.');
  }
  const { user: authUser, assurance } = await deps.verifyIdentity({
    email,
    password,
    totpCode: fields.totpCode,
    totpFactorId: fields.totpFactorId,
  });
  const profile = await deps.store.findActiveProfile(authUser.id);
  await deps.store.logoutTemporary(cookies['vsph.employee.setup']);

  if (!profile || profile.status !== 'active' || profile.id !== authUser.id) {
    // The legacy special onboarding credential path is not replaceable
    // with a fake account or an authenticated session for a disabled user.
    const setupToken = (deps.token ?? newSessionToken)();
    if (authUser.app_metadata?.vsph_employee_enrollment) {
      const accepted = await deps.store.tryTemporaryLogin({
        user: authUser,
        assurance,
        setupHash: hashSessionToken(setupToken),
        passwordHash: hashSessionToken(password),
      });
      if (accepted) {
        return {
          response: { passwordChangeRequired: true, redirect: '/employee-password' },
          cookies: [
            { action: 'clear', name: 'vsph.portal.sid' },
            ...applicationCookieNames(cookies).map((name): CookieInstruction => ({
              action: 'clear', name,
            })),
            { action: 'set', name: 'vsph.employee.setup', value: setupToken, maxAgeMs: 600000 },
          ],
        };
      }
    }
    throw new PortalLoginError(403, 'Account is not enabled or temporary credentials are unavailable.');
  }

  const token = (deps.token ?? newSessionToken)();
  const now = (deps.now ?? Date.now)();
  await deps.store.createPortalSession({
    token_hash: hashSessionToken(token),
    user_id: profile.id,
    expires_at: new Date(now + SESSION_HOURS * 3600000).toISOString(),
  });
  return {
    response: {
      message: 'Signed in.',
      user: {
        id: profile.id,
        name: profile.full_name,
        email: profile.email,
        platformRole: profile.platform_role,
      },
    },
    cookies: [
      { action: 'clear', name: 'vsph.employee.setup' },
      { action: 'set', name: 'vsph.portal.sid', value: token, maxAgeMs: SESSION_HOURS * 3600000 },
    ],
  };
}

export class PortalLoginError extends Error {
  readonly name = 'PortalLoginError';
  constructor(readonly status: number, message: string) {
    super(message);
  }
}
