import { hashSessionToken } from './session-tokens.js';

export type PortalProfile = {
  id: string;
  full_name: string;
  email: string;
  status: string;
  platform_role: string | null;
};
export type PortalSessionRecord = {
  token_hash: string;
  user_id: string;
  expires_at: string;
  profile: PortalProfile | PortalProfile[] | null;
};
export interface PortalSessionStore {
  findByTokenHash(hash: string): Promise<PortalSessionRecord | null>;
}
export type ResolvedPortalSession = {
  session: { token_hash: string; user_id: string; expires_at: string };
  user: PortalProfile;
};

export class PortalSessionError extends Error {
  readonly name = 'PortalSessionError';
}

/**
 * Pure verified-session resolver ported from legacy security.js. The SQL
 * adapter must query only token_hash and bounded joined profile fields.
 * No cookie value from the browser can choose another actor/profile.
 */
export async function resolvePortalSession(
  rawCookie: unknown,
  store: PortalSessionStore,
  nowMs: number = Date.now(),
): Promise<ResolvedPortalSession> {
  if (typeof rawCookie !== 'string' || !rawCookie) {
    throw new PortalSessionError('Please log in.');
  }
  const tokenHash = hashSessionToken(rawCookie);
  const row = await store.findByTokenHash(tokenHash);
  if (
    !row ||
    row.token_hash !== tokenHash ||
    !(new Date(row.expires_at).getTime() > nowMs)
  ) {
    throw new PortalSessionError('Portal session expired. Please log in.');
  }
  const user = row.profile;
  if (
    !user || Array.isArray(user) ||
    user.id !== row.user_id ||
    user.status !== 'active'
  ) {
    throw new PortalSessionError('Account is disabled or unavailable.');
  }
  return {
    session: {
      token_hash: row.token_hash,
      user_id: row.user_id,
      expires_at: row.expires_at,
    },
    user,
  };
}
