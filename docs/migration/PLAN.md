# Migration plan

## Phase 0 — freeze and audit (in progress)
- Reference legacy `3b3a1535873aa0517aea41da32a407f3d9680547` and preserve untouched source.
- Inventory routes/screens/services/migrations and data/permission boundaries.
- Capture original UI in isolated role-specific fixtures with fixed screenshots.
- Create and prioritize route-by-route traceability and test baselines.

## Phase 1 — foundations (scaffold merged; executable validation pending)
- Separate `frontend/`, `backend/`, `docs/`, `shared/`, `workers/`.
- Next.js + TypeScript frontend and Fastify + TypeScript backend.
- Prisma 7 configuration only; **no invented schema or production database access**.
- Root npm workspaces. Generate and review a root lockfile before running CI/container builds.
- Ensure health/login fail closed (no false-ready endpoints).

## Phase 2 — authentication and shell
- Original Inter font, reference login screenshots, CSS and login React UI port are committed (PRs #5–#6). Rendering parity, original top navigation and full login authentication remain pending.
- Identity/MFA verification, opaque token policy, portal-session resolver, product-context policy, and basic HTTP protection are in draft PR #7; not wired to live sessions.
- Preserve Supabase Auth, portal sessions, app sessions, role/tenant enforcement, revocation and SSO.
- Approve screenshots and role/tenant negative tests before advancing.

## Phase 3 — modules in independently reviewed PRs
- Owner dashboard and application catalog
- Organizations, customers, memberships and invitations
- Employees, HR, attendance/leave, account linking
- Projects, milestones/tasks, engineering links, reports
- Finance ledger/journal, notifications, preferences
- External SSO and durable workers

Each PR: source-commit traceability, contract tests, screenshots and no unapproved user-facing changes.

## Phase 4 — system acceptance
- Compare full route/role matrix and audit/transaction semantics.
- Isolated PostgreSQL integration, E2E, accessibility, perf, security/tenant testing.
- Verify backups and actual **offsite restore**, real Supabase Auth sign-ins and provider integrations.

## Phase 5 — staging/deployment/cutover
- Build locked, reviewed Docker images for Next.js, Fastify and workers.
- Run on Hostinger VPS behind Caddy and Cloudflare.
- Cut over `app.vsph.in` only with approval and tested rollback.
- Do not write to current production Supabase or switch DNS during Phases 0–3.

## Unresolved before release
- Private repository visibility (currently public)
- Reproducible npm lockfile and dependency checks
- Controlled source-vs-target screenshot comparisons for all pages and states (original login assets archived)
- Approved isolated staging/restored database for Prisma introspection
- One owner for SQL migration history; no competing Prisma Migrate changes to same tables
- Hostinger VPS credentials/provisioning and official production approval
