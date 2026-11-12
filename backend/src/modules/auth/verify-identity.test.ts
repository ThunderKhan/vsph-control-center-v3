import { describe, expect, it, vi } from 'vitest';
import { IdentityError, validateCredentials, validUuid } from './credentials.js';
import { verifyIdentity } from './verify-identity.js';
import type { IdentityProvider } from './identity-provider.js';

const oneId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const twoId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const credentials = { email: ' USER@EXAMPLE.TEST ', password: 'secret' };

function fakeProvider(overrides: Partial<IdentityProvider> = {}): IdentityProvider {
  return {
    signIn: vi.fn(async () => ({
      data: { userId: oneId, sessionToken: true },
      error: null,
    })),
    getUser: vi.fn(async () => ({
      data: { id: oneId, email: 'user@example.test' },
      error: null,
    })),
    getAssurance: vi.fn(async () => ({
      data: { currentLevel: 'aal1', nextLevel: 'aal1' },
      error: null,
    })),
    listFactors: vi.fn(async () => ({ data: [], error: null })),
    verifyFactor: vi.fn(async () => ({ data: { verified: true }, error: null })),
    getUserAfterMfa: vi.fn(async () => ({
      data: { id: oneId, email: 'user@example.test' }, error: null,
    })),
    signOutLocal: vi.fn(async () => ({ data: null, error: null })),
    ...overrides,
  };
}

describe('legacy credential validation', () => {
  it('normalizes email but never trims password', () => {
    expect(validateCredentials({ email: ' USER@EXAMPLE.TEST ', password: ' secret ' })).toEqual({
      email: 'user@example.test', password: ' secret ', totpCode: '',
    });
    expect(validUuid(oneId)).toBe(true);
    expect(validUuid('not-a-uuid')).toBe(false);
  });

  it.each([
    {}, { email: 'a@test.invalid', password: '' },
    { email: 'a@test.invalid', password: 'a'.repeat(4097) },
    { email: 'a@test.invalid', password: 'secret', totpCode: '12345' },
    { email: 'a@test.invalid', password: 'secret', totpCode: 123456 },
    { email: 'a@test.invalid', password: 'secret', totpFactorId: 'bad-id' },
  ])('rejects malformed credentials with the legacy error', (input) => {
    expect(() => validateCredentials(input)).toThrowError(IdentityError);
    try { validateCredentials(input); } catch (error) {
      expect(error).toMatchObject({ status: 400, code: 'INVALID_CREDENTIAL_FIELDS' });
    }
  });
});

describe('Supabase identity verifier parity', () => {
  it('verifies ordinary identity and always signs out isolated session locally', async () => {
    const provider = fakeProvider();
    const result = await verifyIdentity(credentials, () => provider);
    expect(result).toMatchObject({ assurance: 'aal1', user: { id: oneId } });
    expect(provider.signIn).toHaveBeenCalledWith('user@example.test', 'secret');
    expect(provider.signOutLocal).toHaveBeenCalledOnce();
  });

  it('does not permit another user when expectedUserId is set', async () => {
    const provider = fakeProvider();
    await expect(verifyIdentity(credentials, () => provider, { expectedUserId: twoId }))
      .rejects.toMatchObject({ code: 'IDENTITY_MISMATCH', status: 401 });
    expect(provider.signOutLocal).toHaveBeenCalledOnce();
  });

  it('requires a real TOTP challenge when assurance must be elevated', async () => {
    const provider = fakeProvider({
      getAssurance: vi.fn(async () => ({
        data: { currentLevel: 'aal1', nextLevel: 'aal2' }, error: null,
      })),
      listFactors: vi.fn(async () => ({ data: [
        { id: oneId, name: 'Work authenticator', type: 'totp', status: 'verified' },
      ], error: null })),
    });
    await expect(verifyIdentity(credentials, () => provider))
      .rejects.toMatchObject({
        code: 'MFA_REQUIRED',
        status: 401,
        factors: [{ id: oneId, name: 'Work authenticator' }],
      });
    expect(provider.verifyFactor).not.toHaveBeenCalled();
    expect(provider.signOutLocal).toHaveBeenCalledOnce();
  });

  it('fails closed on unsupported factor rather than password-only login', async () => {
    const provider = fakeProvider({
      getAssurance: vi.fn(async () => ({
        data: { currentLevel: 'aal1', nextLevel: 'aal2' }, error: null,
      })),
      listFactors: vi.fn(async () => ({ data: [
        { id: oneId, name: 'Phone', type: 'phone', status: 'verified' },
      ], error: null })),
    });
    await expect(verifyIdentity(credentials, () => provider))
      .rejects.toMatchObject({ code: 'MFA_METHOD_UNSUPPORTED', status: 403 });
    expect(provider.signOutLocal).toHaveBeenCalledOnce();
  });

  it('requires a chosen TOTP factor when more than one is enrolled', async () => {
    const provider = fakeProvider({
      getAssurance: vi.fn(async () => ({
        data: { currentLevel: 'aal1', nextLevel: 'aal2' }, error: null,
      })),
      listFactors: vi.fn(async () => ({ data: [
        { id: oneId, name: 'Primary', type: 'totp', status: 'verified' },
        { id: twoId, name: 'Backup', type: 'totp', status: 'verified' },
      ], error: null })),
    });
    await expect(verifyIdentity({ ...credentials, totpCode: '123456' }, () => provider))
      .rejects.toMatchObject({ code: 'MFA_REQUIRED', status: 401 });
    expect(provider.verifyFactor).not.toHaveBeenCalled();
    expect(provider.signOutLocal).toHaveBeenCalledOnce();
  });

  it('fails closed if the provider returns a missing verified user', async () => {
    const provider = fakeProvider({
      getUser: vi.fn(async () => ({ data: null, error: null })),
    });
    await expect(verifyIdentity(credentials, () => provider))
      .rejects.toMatchObject({ code: 'AUTH_UNAVAILABLE', status: 503 });
    expect(provider.signOutLocal).toHaveBeenCalledOnce();
  });

  it('requires post-TOTP aal2 and matching identity', async () => {
    const provider = fakeProvider({
      getAssurance: vi.fn()
        .mockResolvedValueOnce({ data: { currentLevel: 'aal1', nextLevel: 'aal2' }, error: null })
        .mockResolvedValueOnce({ data: { currentLevel: 'aal2', nextLevel: 'aal2' }, error: null }),
      listFactors: vi.fn(async () => ({ data: [
        { id: oneId, name: 'Authenticator', type: 'totp', status: 'verified' },
      ], error: null })),
    });
    const result = await verifyIdentity(
      { ...credentials, totpCode: '123456' }, () => provider,
    );
    expect(result.assurance).toBe('aal2');
    expect(provider.verifyFactor).toHaveBeenCalledWith(oneId, '123456');
    expect(provider.getUserAfterMfa).toHaveBeenCalledOnce();
    expect(provider.signOutLocal).toHaveBeenCalledOnce();
  });

  it('rejects a provider sign-out error, never leaking an accepted login', async () => {
    const provider = fakeProvider({
      signOutLocal: vi.fn(async () => ({ data: null, error: { status: 503 } })),
    });
    await expect(verifyIdentity(credentials, () => provider))
      .rejects.toMatchObject({ code: 'AUTH_UNAVAILABLE', status: 503 });
  });

  it('maps invalid and rate-limited provider responses without exposing raw errors', async () => {
    for (const [status, expectedCode] of [[400, 'INVALID_CREDENTIALS'], [429, 'AUTH_RATE_LIMITED']] as const) {
      const provider = fakeProvider({
        signIn: vi.fn(async () => ({
          data: { userId: null, sessionToken: false }, error: { status },
        })),
      });
      await expect(verifyIdentity(credentials, () => provider))
        .rejects.toMatchObject({ code: expectedCode });
    }
  });
});
