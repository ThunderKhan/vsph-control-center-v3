# Node 24 migration verification — not yet passed

This page describes a deterministic, no-production workflow for validating the v3 scaffold. **No successful npm install, TypeScript build, Next.js build, Playwright run, or database test has been observed in this migration environment.**

## Why no lockfile yet?

The local runtime cannot resolve `registry.npmjs.org` or `github.com`. An npm lockfile encodes resolved transitive dependency versions and integrity hashes; inventing those values or copying an unrelated lockfile would produce a misleading or unusable build.

## Developer setup (Windows PowerShell)

Install Node.js 24 LTS and npm, then work in the **new** repository only:

```powershell
git clone https://github.com/ThunderKhan/vsph-control-center-v3.git
cd vsph-control-center-v3
node --version
npm --version

# Dependency-free source integrity tests (can run before installing anything):
npm run test:source-parity

# First-time lockfile generation; requires npm registry access:
npm install --package-lock-only
node scripts/verify-lockfile.mjs

# Inspect the full dependency tree/lockfile before committing:
git diff -- package.json frontend/package.json backend/package.json package-lock.json
npm ci
npm run typecheck
npm run lint
npm run test
npm run build

# Optional isolated browser tests (no production credentials):
npx playwright install chromium
npm run test:e2e
```

After a reviewed `package-lock.json` is committed, run `npm ci` for subsequent reproducible installs. Do not replace `npm ci` with a non-deterministic `npm install` in CI.

## Automated workflow

`.github/workflows/manual-quality-gates.yml` is intentionally **workflow_dispatch only**, because Actions usage may be constrained. It uses an isolated Node 24 GitHub runner without database/secrets. It requires the root lockfile and then runs source checks, TypeScript, lint, Vitest and build. Browser testing is opt-in and requires separate Chromium download.

A green source-check is **not proof of UI pixel parity, real Supabase identity, tenant isolation, migration installation, or deployed readiness**.

## Release gates still blocked

1. Generate/review/commit the root npm workspace lockfile using real package registry resolution.
2. Run TypeScript, lint, Vitest, Next.js and API builds. Fix failures in reviewable PRs.
3. Run controlled screenshots at desktop/mobile/tablet and verify original UI, text and behavior.
4. Obtain an approved isolated Postgres restore and allow **read-only staging** Prisma introspection, never production.
5. Verify session database semantics, tenant/role denial, and provider-driven flows with isolated test accounts.
6. Approve Hostinger VPS/Cloudflare deployment and rehearse rollback **only after parity**.

Do not commit `.env`, API keys, customer records, production database dumps, or login screenshots containing real information.

## November 13, 2026 Windows build and audit findings

Windows Node.js 24.14.1: `npm ci` succeeded, all 16 offline source-parity tests passed, and after PR #11's SVG and Supabase optional-status corrections, all four TypeScript workspace checks passed. ESLint then reported 16 errors (two security cleanup throws from `finally`; 14 browser globals from immutable archived scripts). This follow-up preserves the browser archives as lint-excluded reference data and preserves fail-closed session cleanup without throwing inside `finally`.

The developer's `npm audit --omit=dev` reported five advisories: 1 critical (Next.js) and 4 high (Prisma transitive `deepmerge-ts` and `mysql2`). This branch proposes **Next.js 16.4.6** and the aligned **Prisma 7.10.1** package family, as indicated by the audit's patched dependency paths. This is an *update request*, not a verified resolution; regenerate the real lockfile and repeat the audit before acceptance.

On the developer's existing local checkout, from this PR branch:

```powershell
npm install --package-lock-only
node scripts/verify-lockfile.mjs
npm ci
npm run check
npm audit --omit=dev
npm audit
git status --short
```

Do not run `npm audit fix --force`; review the actual lockfile/dependency diff and rerun tests before committing. If checks pass, commit and push the root `package-lock.json` to the same PR branch. Do not commit `node_modules`, environment values, or provider tokens.

Next.js 16.4.6 changes the framework from the 16.3 line and requires functional/UI regression verification, including split login, React hydration and app-router routing parity. No browser or production checks were performed as part of this source change.
