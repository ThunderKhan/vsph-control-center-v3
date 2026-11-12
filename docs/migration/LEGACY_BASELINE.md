# Frozen legacy baseline (12 November 2026)

**Original repository:** https://github.com/ThunderKhan/vsph-control-center

**Source commit:** `3b3a1535873aa0517aea41da32a407f3d9680547`

**New repository:** https://github.com/ThunderKhan/vsph-control-center-v3

The source is an Express 5 + vanilla HTML/CSS/JavaScript Node.js service using Supabase Auth and managed PostgreSQL. The source includes the live-domain runbooks but does not prove production readiness. Its source repository and database remain unchanged by this migration.

## Source inventory confirmed

- Root: `server.js`, `security.js`, `db.js`, `DESIGN.md`, `Dockerfile`, `package.json`
- `routes/`: auth, employee, HRMS, calendar, projects, finance, finance journal, organizations, customers, onboarding, invitations, notifications, product catalog, profile, sessions, GitHub delivery, Music and Outreach SSO.
- `public/`: custom styles and scripts for login, dashboards, employee management, HRMS, Projects, finance, owner view, navigation and calendar.
- `views/`: server-rendered auth and static portal view templates.
- `services/`: role and database logic, invitations, notification workers, GitHub sync, readiness.
- `supabase/`: checksummed SQL migration manifest and schema, including privileged RPC authorization and audit logic.
- `tests/`: Node tests, database-isolation tests and Playwright browser tests.
- `docs/`: extensive architecture and operations guides. **Do not discard existing source documentation**.

## High-risk preservation boundaries

- Supabase users, identities, login and portal/app sessions
- Owner/HR/employee/customer permissions and cross-tenant denial
- Employee onboarding, HRMS/leave/attendance/identity links
- Project creation, assignment, milestones, tasks and audit updates
- Financial ledger, paise arithmetic and transactional receipt caps
- Customer organization memberships, product subscriptions and grants
- Invitation issuance, outbox, redemption, revocation and worker durability
- Music/Outreach SSO and GitHub App delivery integrations

## Visual source-of-truth references

- Exact `DESIGN.md` copied from frozen source into this repository.
- Exact `public/auth.css` and `public/crm-auth.css` copied into `docs/reference/styles/`.
- Original legacy login screenshots now also retained in `docs/reference/screenshots/` with matching GitHub blob SHA-1 hashes.
- Exact Inter font binary is now copied to `frontend/public/fonts/`, with its SIL OFL license preserved. Matching source blob hash confirmed. Pixel-level screenshot comparisons remain a gate.
- No v3 page is visually accepted yet.

Never treat the legacy documentation's fixture acceptance as proof of real hosted Supabase acceptance.
