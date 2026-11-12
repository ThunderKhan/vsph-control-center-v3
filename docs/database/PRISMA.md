# Prisma 7 adoption without rewriting production schema

**Prisma is approved. Production database migrations are not.**

The original schema is maintained by a checksummed SQL manifest with RLS, privileged functions, triggers, audit rows, and transactional domain behavior. Creating a new Prisma baseline or running `prisma migrate dev` on this target can destroy critical assumptions.

## Safe sequence

1. Obtain an explicitly approved, independently restored isolated PostgreSQL staging database with equivalent roles, extensions and the exact SQL schema; verify backup/restore first.
2. Give the introspection identity read-only privileges; no production secrets in repository or output.
3. Review `backend/prisma/schema.prisma` produced from a staged `prisma db pull`, mapping names with `@@map` and `@map` where needed. Introspection is not schema migration.
4. Keep existing native SQL functions and audit/finance authorization as the initial source of truth.
5. Add Prisma Client with `@prisma/adapter-pg`, a staging-only pooled runtime `DATABASE_URL`, and a separate direct CLI `DIRECT_URL`. Ensure SSL verification and limited SQL role.
6. Make a deliberate decision on one migration owner before any SQL writes. Prisma must not recreate or overwrite the original migration history.
7. Test cross-tenant access, revocation, monetary exactness, transactions, session behaviour and connection pooling against an isolated fixture.
8. Only after reviewed equivalence may a single domain endpoint use Prisma in staging.

Prisma client generator in v7 uses `prisma-client` with an explicit output path. The driver adapter is required for direct runtime connections. All generated Prisma code stays server-only.

References: https://www.prisma.io/docs/orm/v7/prisma-schema/overview/generators and https://www.prisma.io/docs/orm/v7/core-concepts/supported-databases/database-drivers

**No schema introspection or database command has been executed as part of the foundation.**
