/**
 * Ported from legacy services/verify-identity.js at
 * 3b3a1535873aa0517aea41da32a407f3d9680547.
 * Provider MFA and exact credential limits are security contracts.
 */
export type AuthFactor = { id: string; name: string };

export class IdentityError extends Error {
  readonly name = 'IdentityError';
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly factors?: AuthFactor[],
  ) {
    super(message);
  }
}

export function authUnavailable(): IdentityError {
  return new IdentityError(
    503,
    'AUTH_UNAVAILABLE',
    'Identity verification is temporarily unavailable. Try again later.',
  );
}

export type Credentials = {
  email: string;
  password: string;
  totpCode: string;
  totpFactorId?: string;
};

export const validUuid = (value: unknown): value is string =>
  typeof value === 'string' &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);

export function validateCredentials(value: unknown): Credentials {
  const input: Record<string, unknown> =
    value && typeof value === 'object' && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : {};
  const { email, password, totpFactorId } = input;
  const totpCode = input.totpCode === undefined ? '' : input.totpCode;
  if (
    typeof email !== 'string' ||
    !email.trim() ||
    email.length > 254 ||
    typeof password !== 'string' ||
    !password ||
    password.length > 4096 ||
    typeof totpCode !== 'string' ||
    (totpCode !== '' && !/^\d{6}$/.test(totpCode)) ||
    (totpFactorId !== undefined && !validUuid(totpFactorId))
  ) {
    throw new IdentityError(
      400,
      'INVALID_CREDENTIAL_FIELDS',
      'Provide your email, password and a six-digit authenticator code when requested.',
    );
  }
  return {
    email: email.trim().toLowerCase(),
    password,
    totpCode,
    ...(totpFactorId !== undefined ? { totpFactorId: totpFactorId as string } : {}),
  };
}

export function identityErrorBody(error: IdentityError) {
  return {
    code: error.code,
    message: error.message,
    ...(error.factors ? { factors: error.factors } : {}),
  };
}
