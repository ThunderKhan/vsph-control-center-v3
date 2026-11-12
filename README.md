# VSPH Control Center v3

**Migration foundation only — not a working replacement, not deployed, and not authorized for production database access.**

This is an independently versioned technology port of [VSPH Control Center](https://github.com/ThunderKhan/vsph-control-center). Existing user-facing appearance, copy, navigation, role permissions, data behavior and workflows are contractual parity requirements. **No redesign, content change, or feature enhancement is permitted without explicit approval.**

## Target architecture

- `frontend/`: Next.js (App Router), React, TypeScript; ultimately Tailwind CSS + shadcn/ui without visual changes
- `backend/`: Node.js 24, Fastify, TypeScript, Prisma ORM 7
- `shared/`: shared typed API contracts
- `workers/`: separate durable background processing (NOT ported yet)
- `docs/`: architecture, source-to-target traceability, visual/functional parity, release gates
- PostgreSQL + Supabase Auth remain the data and identity foundations
- Deployment target: Hostinger VPS + Docker Compose + Caddy behind Cloudflare

**Current development status:** The Next.js login interface has been ported in source with original CSS and exact copied Inter font. Original login screenshots are archived. The Fastify readiness and login endpoints remain fail-closed with HTTP 503; the browser UI is not connected to working authentication. Security primitives and identity/session/entitlement logic are under review, not deployed. Do not publish this as an application. Visual parity is not yet certified.

## Source baseline

- Original: https://github.com/ThunderKhan/vsph-control-center
- Frozen comparison commit: `3b3a1535873aa0517aea41da32a407f3d9680547`
- Full details: `docs/migration/LEGACY_BASELINE.md`
- Parity contract: `docs/migration/PARITY_REQUIREMENTS.md`
- Migration plan: `docs/migration/PLAN.md`

## Development (after installing dependencies)

Use Node.js 24 and npm. A reviewed `package-lock.json` is **not yet committed**, because registry/network package resolution has not been completed. This is a release-blocking setup task, not a reason to use unpinned dependencies in production.

```sh
npm install
npm run test:source-parity
npm run typecheck
npm run test
npm run dev:api
# In a second terminal:
npm run dev:web
```

The v3 frontend has a source-level login port but no migrated authenticated dashboard or other business page. The Fastify API at `http://localhost:4000/api/health` must return HTTP 503 until a real, safely verified database/identity dependency check is implemented.

**Do not run `prisma migrate dev`, `prisma db push`, `prisma migrate deploy`, or production `prisma db pull` against the existing Supabase instance.** Introspection must first be performed against an approved, restored, read-only staging replica, and schema/migration ownership agreed with the source SQL migration manifest.

The original project is unchanged. Nothing in this repository performs hosted writes, creates users, sends email, or provisions infrastructure.
