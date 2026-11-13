# Organization frontend handoff — draft migration boundary

## Confirmed repositories

- Legacy source/reference: `ThunderKhan/vsph-control-center`, frozen at `3b3a1535873aa0517aea41da32a407f3d9680547`.
- Organization's legacy copy: `vsph-global/vsph-control-center` (different Git history; sampled original `DESIGN.md`, login CSS, dashboard HTML, auth route and migration manifest have byte-identical Git blobs).
- Organization frontend target: **`vsph-global/app-vsph-frontend`**, a default Next.js scaffold (Next.js 16.4.6, React 19.3.0 at inspection).
- User-owned temporary migration/reference workspace: `ThunderKhan/vsph-control-center-v3` (Next.js 16.3.5 + Fastify + Prisma).

## Recommended source-of-truth decision

Use `vsph-global/app-vsph-frontend` as the **authoritative frontend** from the first reviewed page migration. Do not maintain divergent implementations of the same UI in both repositories. Retain `frontend/` in this v3 repository only as a frozen migration reference until ownership and deployment integration are approved. Backend API ownership must be separately agreed with the organization; don't assume this personal repository is a production backend.

## Important access blocker

The connected GitHub integration can read `vsph-global/app-vsph-frontend`, but a `create_branch` attempt on November 13, 2026 was rejected by GitHub with `403 Resource not accessible by integration`. **No organization repository file was changed.** An organization owner needs to authorize the connected GitHub application for that repository with appropriate contents/pull-request permissions, or a human collaborator with repo write access must push a reviewed branch. Never copy secrets to overcome this.

## Handoff order

1. Fix v3 TypeScript errors and commit a reviewed root npm lockfile from the user's successful Windows npm resolution. Review `npm audit`, especially 1 critical and 4 high advisories.
2. Verify the original login UI source against Next.js and React versions in the organization frontend. Copy **source components and reference assets only**. Do **not** replace the organization's `package.json`, `package-lock.json`, Next config or app layout blindly.
3. Preserve original Inter `.woff2`, `fonts.css`, `auth.css`, `crm-auth.css`, JSX structure, text, sizes, and mobile breakpoints. Remove default starter Geist/Tailwind typography and CSS resets *where they alter the original login appearance*; separately review the impact on other organization routes.
4. Port `frontend/src/features/auth/`, `frontend/src/app/login/`, and `frontend/src/app/apps/[app]/login/` from the verified source branch into the organization's Next.js `src/` layout, preserving exact legacy DOM anchors. Route app sessions and API contracts through the organization's approved backend and a same-origin reverse proxy; **no working backend exists for this new frontend yet**.
5. Keep login non-production until server-side session auth, MFA, employee temporary credentials, app-level role gating, secure cookies, and origin protections are verified in isolated staging.
6. Run Node 24 install, TypeScript, lint, unit, Playwright desktop/tablet/mobile screenshot diffs against the original under fixed fixture/browser/font conditions. Mark visual/functional parity complete only after evidence.
7. Port the remaining dashboard, employees, HRMS, projects, finance, customers, organization/product access, notifications, calendars, search, and admin pages into the **organization** frontend, preserving every user-facing behavior.

## Work remaining (rough inventory, not a feature-count acceptance metric)

- Original contains 32 HTML files (including partials), 26 JavaScript route modules, 40 public JavaScript files, 28 public CSS files and 25 JavaScript service files.
- Only login UI has a preliminary React implementation. Other user-facing modules and almost all operational backend behavior have **not** been migrated.
- The Prisma schema/models, real session persistence, Auth staging tests, UI screenshot parity, worker process replacement, API routes and release/runbook tests are not complete.
- Therefore v3 must not be represented as ready for a complete organization/frontend production handoff. Starting a staged **login-only PR** is reasonable once write access and build verification are available.

**No deployment, DNS, production database, or original source changes have been authorized or performed.**
