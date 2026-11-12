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

**Current development status:** There is a scaffold, an intentionally blank frontend route, and a Fastify readiness endpoint that always fails closed with HTTP 503. This is deliberate: none of the live identity, database, or business modules is represented as complete. Do not publish this as an application. The legacy visual source styles are preserved in `docs/reference/styles/`, but not imported until the original font/assets and screenshots have been recovered and compared.

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
npm run typecheck
npm run test
npm run dev:api
# In a second terminal:
npm run dev:web
```

The v3 frontend currently has no migrated product pages. The Fastify API at `http://localhost:4000/api/health` must return HTTP 503 until a real, safely verified database/identity dependency check is implemented.

**Do not run `prisma migrate dev`, `prisma db push`, `prisma migrate deploy`, or production `prisma db pull` against the existing Supabase instance.** Introspection must first be performed against an approved, restored, read-only staging replica, and schema/migration ownership agreed with the source SQL migration manifest.

The original project is unchanged. Nothing in this repository performs hosted writes, creates users, sends email, or provisions infrastructure.
