import {
  IdentityError, authUnavailable, validateCredentials, validUuid,
} from './credentials.js';
import type { IdentityProvider, ProviderUser } from './identity-provider.js';

/**
 * Matches legacy services/verify-identity.js credential, MFA, identity,
 * and isolated-session cleanup semantics. There is deliberately no
 * session cookie creation here. That requires reviewed Prisma models and
 * current employee/tenant authorization checks.
 */
export async function verifyIdentity(
  input: unknown,
  providerFactory: () => IdentityProvider,
  options: { expectedUserId?: string } = {},
): Promise<{ user: ProviderUser; assurance: 'aal1' | 'aal2' }> {
  const credentials = validateCredentials(input);
  let provider: IdentityProvider | undefined;
  let sessionCreated = false;
  let outcome: { user: ProviderUser; assurance: 'aal1' | 'aal2' } | undefined;
  let failure: IdentityError | undefined;
  try {
    outcome = await (async () => {
      provider = providerFactory();
    const signed = await provider.signIn(credentials.email, credentials.password);
    sessionCreated = Boolean(signed.data?.sessionToken);
    if (signed.error) {
      if (signed.error.status === 429) {
        throw new IdentityError(
          429, 'AUTH_RATE_LIMITED', 'Too many authentication attempts. Try again later.',
        );
      }
      if (!signed.error.status || signed.error.status >= 500) throw authUnavailable();
      throw new IdentityError(401, 'INVALID_CREDENTIALS', 'Invalid credentials or email not confirmed.');
    }
    if (!sessionCreated || !signed.data?.userId) throw authUnavailable();

    const current = await provider.getUser();
    const user = current.data;
    if (current.error || !user?.id) throw authUnavailable();
    if (
      user.id !== signed.data.userId ||
      user.email?.toLowerCase() !== credentials.email ||
      (options.expectedUserId && user.id !== options.expectedUserId)
    ) {
      throw new IdentityError(
        401, 'IDENTITY_MISMATCH', 'Use your signed-in account to verify this action.',
      );
    }

    const level = await provider.getAssurance();
    if (
      level.error ||
      !['aal1', 'aal2'].includes(level.data?.currentLevel ?? '') ||
      !['aal1', 'aal2'].includes(level.data?.nextLevel ?? '')
    ) throw authUnavailable();
    let assurance = level.data!.currentLevel as 'aal1' | 'aal2';
    const requiresMfa = level.data!.nextLevel === 'aal2' ||
      user.factors?.some((factor) => factor.status === 'verified');

    if (requiresMfa && assurance !== 'aal2') {
      const listed = await provider.listFactors();
      if (listed.error || !Array.isArray(listed.data)) throw authUnavailable();
      const totp = listed.data
        .filter((factor) => factor.type === 'totp' && factor.status === 'verified' &&
          validUuid(factor.id))
        .sort((a, b) => a.id.localeCompare(b.id));
      if (!totp.length) {
        throw new IdentityError(
          403, 'MFA_METHOD_UNSUPPORTED',
          'This account requires a second factor that this portal cannot verify. Contact your administrator; password-only access is denied.',
        );
      }
      const factors = totp.map((factor) => ({ id: factor.id, name: factor.name.slice(0, 80) }));
      if (!credentials.totpCode || (!credentials.totpFactorId && totp.length > 1)) {
        throw new IdentityError(
          401, 'MFA_REQUIRED', 'Enter the current code from your enrolled authenticator.', factors,
        );
      }
      const selected = totp.find(
        (factor) => factor.id === (credentials.totpFactorId ?? totp[0]?.id),
      );
      if (!selected) {
        throw new IdentityError(
          401, 'MFA_INVALID', 'Authenticator verification failed. Try a current code.',
        );
      }
      const verified = await provider.verifyFactor(selected.id, credentials.totpCode);
      if (verified.error) {
        if (!verified.error.status || verified.error.status >= 500) throw authUnavailable();
        throw new IdentityError(
          401, 'MFA_INVALID', 'Authenticator verification failed. Try a current code.',
        );
      }
      if (!verified.data?.verified) throw authUnavailable();
      const after = await provider.getAssurance();
      const verifiedUser = await provider.getUserAfterMfa();
      if (
        after.error ||
        after.data?.currentLevel !== 'aal2' ||
        verifiedUser.error ||
        verifiedUser.data?.id !== user.id
      ) throw authUnavailable();
      assurance = 'aal2';
    }
      return { user, assurance };
    })();
  } catch (error: unknown) {
    failure = error instanceof IdentityError ? error : authUnavailable();
  }

  // Cleanup occurs AFTER the verification attempt settles, never inside
  // finally: a failed sign-out still overrides any verified result or MFA
  // challenge and prevents the caller from issuing a portal session.
  if (sessionCreated && provider) {
    try {
      const signOut = await provider.signOutLocal();
      if (signOut.error) failure = authUnavailable();
    } catch {
      failure = authUnavailable();
    }
  }

  if (failure) throw failure;
  if (!outcome) throw authUnavailable();
  return outcome;
}
