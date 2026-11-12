# Preserved SQL schema baseline

Original repository: https://github.com/ThunderKhan/vsph-control-center

Frozen source commit: `3b3a1535873aa0517aea41da32a407f3d9680547`

## What was transferred

- `supabase/schema.sql` — the original base schema, never executed by v3.
- `supabase/migration-manifest.json` — the original checksummed dependency ledger, unchanged.
- `supabase/migrations/` — all **38 original SQL migration files**, byte-identical to the frozen source.

GitHub source/destination blob SHA-1 matches were verified for all 40 files (38 migrations, base schema and manifest).

`tests/source-sql-manifest.test.mjs` checks the SHA-256 digests recorded in the original manifest, dependency graph, file allowlist and the known duplicate legacy Music version `20261030`; it is included in the dependency-free source test runner. These Node tests must still be executed in a checkout before claiming an automated pass.

## Why not Prisma Migrate?

The original SQL includes application authorization, RLS, stored functions, triggers, finance ledger operations and session/invitation state transitions. Prisma schema introspection cannot represent all those behaviors faithfully. **Existing SQL remains canonical** until the user approves a completely separate, reviewable ownership change.

Never:
- run `prisma migrate dev`, `prisma migrate deploy`, `prisma db push` or bootstrap/schema SQL on production;
- silently renumber the two historical Music migrations or replay a bootstrap on an existing database;
- substitute a synthetic `schema.prisma` for introspection of a restored staging database;
- put production DB credentials, hosted backups, client data or Auth hashes into Git.

Staging introspection will require a separately restored environment, read-only SQL role, explicit target host/name, and independently checked catalog fingerprints. The `backend/prisma.config.ts` URL gate enforces operator-provided approval/restore flags and target matching. **Flags do not prove actual restore or database privilege safety**; they are extra guardrails.

The original operational runbooks on partial migration history, safety, backup/restore and release gates remain relevant and must be consulted before any schema install.
