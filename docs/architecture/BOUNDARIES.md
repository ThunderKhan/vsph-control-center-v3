# System boundaries

1. Browser/Next.js calls one-origin `/api/*` handled by Fastify through the reverse proxy.
2. Next.js server rendering must never independently implement authorization or business mutations bypassing Fastify. No service-role or DATABASE_URL credentials in client bundles.
3. Fastify validates current identity, account state, role, organization, project access and session revocation for **each request**, rather than trusting menu visibility.
4. Prisma handles ordinary typed data access only after the **existing** schema and functions are mapped. RLS does not follow automatically from Supabase Auth into a privileged SQL connection.
5. PostgreSQL retains ownership of existing atomic ledgers, invitation state, project authorization, auditing, triggers and checked migrations until each is explicitly ported with proof.
6. Background workers are independent processes that preserve retries, leases, idempotency and durable state; do not turn them into Next.js cron endpoints.
7. Cloudflare protects public edge traffic; Hostinger VPS runs Caddy, Next.js, Fastify and workers. Supabase remains hosted separately.

Before any production cutover: verified private backup and restore, fully passing role/tenant tests, and identical UI screenshots at fixed viewports.
