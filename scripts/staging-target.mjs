/**
 * Pure preflight for Prisma CLI direct URL. No connection or logging of DSNs.
 *
 * Approval flags are guardrails against accidental access, not proof that a
 * database has actually been restored, validated or granted read-only access.
 */
export function stagingDirectUrl(env = process.env) {
  const raw = env.DIRECT_URL ?? '';
  if (!raw) return ''; // prisma generate and schema validation may run offline.
  if (
    env.STAGING_INSPECTION_APPROVED !== 'true' ||
    env.STAGING_RESTORE_VERIFIED !== 'true' ||
    !env.STAGING_DATABASE_HOST ||
    !env.STAGING_DATABASE_NAME ||
    !env.STAGING_READ_ONLY_ROLE
  ) throw new Error('Prisma requires an explicitly approved, verified isolated staging target.');

  let url;
  try { url = new URL(raw); } catch { throw new Error('Invalid staging connection URL.'); }
  if (!['postgresql:', 'postgres:'].includes(url.protocol) ||
      url.hostname !== env.STAGING_DATABASE_HOST ||
      decodeURIComponent(url.pathname.slice(1)) !== env.STAGING_DATABASE_NAME ||
      decodeURIComponent(url.username) !== env.STAGING_READ_ONLY_ROLE ||
      !url.password || url.hash ||
      [...url.searchParams.keys()].some((key) => key !== 'sslmode')) {
    throw new Error('Staging database target does not match approved read-only connection.');
  }
  const local = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
  if (!local && url.searchParams.get('sslmode') !== 'verify-full') {
    throw new Error('Remote staging introspection requires TLS hostname verification.');
  }
  if (env.PRODUCTION_DATABASE_HOST && url.hostname === env.PRODUCTION_DATABASE_HOST) {
    throw new Error('Staging and production database hosts must be separate.');
  }
  return raw;
}
