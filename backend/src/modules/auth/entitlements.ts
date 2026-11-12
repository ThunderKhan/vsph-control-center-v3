/**
 * Pure, cross-tenant-safe port of legacy access-policy.js.
 * Product access requires ALL of current membership, role, enabled grant,
 * active organization and active/trial subscription. Platform admin is NOT
 * an implicit product user or customer organization member.
 */
export type ActiveIdentity = { id: string; status: string };
export type ActiveApplication = { id: string; status: string };
export type Organization = { id: string; status: string; [key: string]: unknown };
export type Subscription = {
  application_id: string;
  organization_id: string;
  status: string;
  starts_at?: string | null;
  ends_at?: string | null;
};
export type AppGrant = { application_id: string; organization_id: string; status: string };
export type Membership = { user_id: string; organization_id: string; status: string };
export type UserAppRole = {
  user_id: string;
  application_id: string;
  organization_id: string;
  role_code: string;
};

export function validSubscription(sub: Subscription, nowMs: number = Date.now()): boolean {
  return ['active', 'trial'].includes(sub.status) &&
    (!sub.starts_at || new Date(sub.starts_at).getTime() <= nowMs) &&
    (!sub.ends_at || new Date(sub.ends_at).getTime() > nowMs);
}

export function permittedContexts<T extends Organization>({
  user, app, organizations, subscriptions, grants, memberships = [], roles = [],
  nowMs = Date.now(),
}: {
  user: ActiveIdentity | null;
  app: ActiveApplication | null;
  organizations: T[];
  subscriptions: Subscription[];
  grants: AppGrant[];
  memberships?: Membership[];
  roles?: UserAppRole[];
  nowMs?: number;
}): Array<T & { role: string }> {
  if (!user || user.status !== 'active' || !app || app.status !== 'active') return [];
  const subscribed = new Set(
    subscriptions.filter((s) => s.application_id === app.id && validSubscription(s, nowMs))
      .map((s) => s.organization_id),
  );
  const enabled = new Set(
    grants.filter((g) => g.application_id === app.id && g.status === 'enabled')
      .map((g) => g.organization_id),
  );
  const memberOrgs = new Set(
    memberships.filter((m) => m.user_id === user.id && m.status === 'active')
      .map((m) => m.organization_id),
  );
  const userRoles = roles.filter((r) => r.user_id === user.id && r.application_id === app.id);
  return organizations
    .filter((o) => o.status === 'active' && subscribed.has(o.id) && enabled.has(o.id))
    .filter((o) => memberOrgs.has(o.id) && userRoles.some((r) => r.organization_id === o.id))
    .map((o) => {
      const role = userRoles.find((r) => r.organization_id === o.id);
      // The preceding filter proves a role exists; this additional check
      // prevents accidental grants if the filter is refactored later.
      if (!role) throw new Error('Inconsistent entitlement projection');
      return { ...o, role: role.role_code };
    });
}
