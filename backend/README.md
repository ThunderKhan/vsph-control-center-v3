# Fastify / Prisma backend

This folder is a scaffold only. The only HTTP endpoints are fail-closed `/api/health` and `/api/auth/login` placeholders. There is no Supabase connection, working login, Prisma model mapping, finance or HRMS API yet.

Prisma 7 requires `@prisma/adapter-pg` for direct PostgreSQL runtime connections and uses `prisma.config.ts` for CLI database URL configuration. No generated client is committed.

**Never apply `prisma migrate` or `db push` to the existing Supabase project.** Read `../docs/database/PRISMA.md` and reconcile the existing SQL manifest before any database command.
