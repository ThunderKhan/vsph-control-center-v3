import { describe, expect, it, vi } from 'vitest';
import { resolvePortalSession, type PortalSessionRecord, type PortalSessionStore } from './portal-session.js';
import { hashSessionToken } from './session-tokens.js';

const now = Date.parse('2026-11-12T00:00:00.000Z');
const cookie = 'isolated-test-cookie-never-a-real-session';
const token_hash = hashSessionToken(cookie);
const activeUser = {
  id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  full_name: 'Test Employee',
  email: 'employee@example.test',
  status: 'active',
  platform_role: null,
};
const record: PortalSessionRecord = {
  token_hash,
  user_id: activeUser.id,
  expires_at: '2026-11-12T03:00:00.000Z',
  profile: activeUser,
};
const store = (row: PortalSessionRecord | null): PortalSessionStore => ({
  findByTokenHash: vi.fn(async () => row),
});

describe('legacy portal session resolution', () => {
  it('rejects missing cookie and never queries the store', async () => {
    const repo = store(record);
    await expect(resolvePortalSession(undefined, repo, now))
      .rejects.toThrow('Please log in.');
    expect(repo.findByTokenHash).not.toHaveBeenCalled();
  });
  it('resolves a live token only to its same active profile', async () => {
    const repo = store(record);
    const result = await resolvePortalSession(cookie, repo, now);
    expect(repo.findByTokenHash).toHaveBeenCalledWith(token_hash);
    expect(result.session.token_hash).toBe(token_hash);
    expect(result.user.id).toBe(activeUser.id);
  });
  it('rejects a missing or expired session', async () => {
    await expect(resolvePortalSession(cookie, store(null), now))
      .rejects.toThrow('Portal session expired.');
    await expect(resolvePortalSession(cookie, store(record), Date.parse(record.expires_at)))
      .rejects.toThrow('Portal session expired.');
  });
  it('rejects disabled users, mismatched identities and ambiguous joins', async () => {
    for (const bad of [
      { ...record, profile: { ...activeUser, status: 'disabled' } },
      { ...record, user_id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' },
      { ...record, profile: [activeUser] },
      { ...record, profile: null },
      { ...record, token_hash: 'f'.repeat(64) },
    ]) {
      await expect(resolvePortalSession(cookie, store(bad), now)).rejects.toThrow();
    }
  });
});
