/**
 * Narrow, per-attempt identity provider contract. Kept separate from the
 * database/Prisma session layer; no provider session JWT is persisted.
 */
export type ProviderError = { status?: number | null | undefined };
export type ProviderResult<T> = { data: T | null; error: ProviderError | null };
export type ProviderUser = {
  id: string;
  email?: string | null;
  factors?: Array<{ status: string }>;
};
export type ProviderFactor = {
  id: string;
  name: string;
  type: string;
  status: string;
};

export interface IdentityProvider {
  signIn(email: string, password: string): Promise<ProviderResult<{
    userId: string | null;
    sessionToken: boolean;
  }>>;
  getUser(): Promise<ProviderResult<ProviderUser>>;
  getAssurance(): Promise<ProviderResult<{ currentLevel: string; nextLevel: string }>>;
  listFactors(): Promise<ProviderResult<ProviderFactor[]>>;
  verifyFactor(factorId: string, code: string): Promise<ProviderResult<{ verified: boolean }>>;
  getUserAfterMfa(): Promise<ProviderResult<ProviderUser>>;
  signOutLocal(): Promise<ProviderResult<null>>;
}
