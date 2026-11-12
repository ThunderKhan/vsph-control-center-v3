import { createClient } from '@supabase/supabase-js';
import { authUnavailable } from './credentials.js';
import type { IdentityProvider, ProviderError } from './identity-provider.js';

/**
 * Supabase Auth is for identity verification only. Prisma owns ordinary data
 * access after reviewed schema introspection. Make a distinct Auth client for
 * each credential verification to avoid sharing a session across requests.
 */
export function createSupabaseIdentityProvider(config: {
  url: string;
  publishableKey: string;
}): IdentityProvider {
  if (
    !config.url ||
    !config.publishableKey ||
    !/^https:\/\//.test(config.url) ||
    config.publishableKey.startsWith('YOUR_')
  ) throw authUnavailable();
  const auth = createClient(config.url, config.publishableKey, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
      detectSessionInUrl: false,
    },
  }).auth;
  const errorStatus = (error: { status?: number } | null): ProviderError | null =>
    error ? { status: error.status } : null;

  const getUser = async () => {
    const result = await auth.getUser();
    return {
      data: result.data.user ? {
        id: result.data.user.id,
        email: result.data.user.email ?? null,
        app_metadata: result.data.user.app_metadata,
        email_confirmed_at: result.data.user.email_confirmed_at ?? null,
        ...(result.data.user.factors
          ? { factors: result.data.user.factors.map((factor) => ({ status: factor.status })) }
          : {}),
      } : null,
      error: errorStatus(result.error),
    };
  };
  return {
    async signIn(email, password) {
      const result = await auth.signInWithPassword({ email, password });
      return {
        data: {
          userId: result.data.user?.id ?? null,
          sessionToken: Boolean(result.data.session?.access_token),
        },
        error: errorStatus(result.error),
      };
    },
    getUser,
    async getAssurance() {
      const result = await auth.mfa.getAuthenticatorAssuranceLevel();
      return {
        data: result.data ? {
          currentLevel: result.data.currentLevel ?? '',
          nextLevel: result.data.nextLevel ?? '',
        } : null,
        error: errorStatus(result.error),
      };
    },
    async listFactors() {
      const result = await auth.mfa.listFactors();
      return {
        data: result.data?.all?.map((factor) => ({
          id: factor.id,
          name: String(factor.friendly_name || 'Authenticator'),
          status: factor.status,
          type: factor.factor_type,
        })) ?? null,
        error: errorStatus(result.error),
      };
    },
    async verifyFactor(factorId, code) {
      const result = await auth.mfa.challengeAndVerify({ factorId, code });
      return { data: { verified: !result.error }, error: errorStatus(result.error) };
    },
    getUserAfterMfa: getUser,
    async signOutLocal() {
      const result = await auth.signOut({ scope: 'local' });
      return { data: null, error: errorStatus(result.error) };
    },
  };
}
