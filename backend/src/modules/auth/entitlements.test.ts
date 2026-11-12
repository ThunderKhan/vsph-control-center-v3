import { describe, expect, it } from 'vitest';
import { permittedContexts, validSubscription } from './entitlements.js';

const now = Date.parse('2026-11-12T00:00:00Z');
const user = { id: 'test-user', status: 'active' };
const app = { id: 'test-app', status: 'active' };
const org = { id: 'org-A', status: 'active', name: 'Test Organization' };

function context(overrides: Record<string, unknown> = {}) {
  return {
    user, app, organizations: [org],
    subscriptions: [{ application_id: app.id, organization_id: org.id, status: 'active' }],
    grants: [{ application_id: app.id, organization_id: org.id, status: 'enabled' }],
    memberships: [{ user_id: user.id, organization_id: org.id, status: 'active' }],
    roles: [{
      user_id: user.id, organization_id: org.id, application_id: app.id, role_code: 'manager',
    }],
    nowMs: now,
    ...overrides,
  };
}

describe('legacy product-context policy', () => {
  it('requires membership, app role, active subscription and enabled grant together', () => {
    expect(permittedContexts(context())).toEqual([{ ...org, role: 'manager' }]);
    for (const missing of ['subscriptions', 'grants', 'memberships', 'roles']) {
      expect(permittedContexts(context({ [missing]: [] }))).toEqual([]);
    }
  });

  it('rejects revoked account/app, disabled grant or expired subscription', () => {
    expect(permittedContexts(context({ user: { ...user, status: 'disabled' } }))).toEqual([]);
    expect(permittedContexts(context({ app: { ...app, status: 'disabled' } }))).toEqual([]);
    expect(permittedContexts(context({ organizations: [{ ...org, status: 'disabled' }] }))).toEqual([]);
    expect(permittedContexts(context({ grants: [{
      application_id: app.id, organization_id: org.id, status: 'disabled',
    }] }))).toEqual([]);
    expect(permittedContexts(context({ subscriptions: [{
      application_id: app.id, organization_id: org.id, status: 'active',
      ends_at: new Date(now).toISOString(),
    }] }))).toEqual([]);
  });

  it('does not infer product membership from platform owner privileges', () => {
    expect(permittedContexts(context({
      user: { ...user, platform_role: 'super_admin' },
      memberships: [],
    }))).toEqual([]);
  });

  it('blocks different-tenant membership, grants or application roles', () => {
    expect(permittedContexts(context({ memberships: [{
      user_id: user.id, organization_id: 'org-B', status: 'active',
    }] }))).toEqual([]);
    expect(permittedContexts(context({ roles: [{
      user_id: user.id, organization_id: org.id, application_id: 'different-app', role_code: 'manager',
    }] }))).toEqual([]);
  });

  it('retains original inclusive start and exclusive end subscription boundaries', () => {
    expect(validSubscription({
      application_id: app.id, organization_id: org.id, status: 'trial',
      starts_at: new Date(now).toISOString(),
      ends_at: new Date(now + 1).toISOString(),
    }, now)).toBe(true);
    expect(validSubscription({
      application_id: app.id, organization_id: org.id, status: 'trial',
      starts_at: new Date(now).toISOString(),
      ends_at: new Date(now).toISOString(),
    }, now)).toBe(false);
  });
});
