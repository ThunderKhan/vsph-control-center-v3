# Target stack (approved migration constraints)

- Frontend: Next.js App Router + React + TypeScript; Tailwind CSS and shadcn/ui may be used internally **only when the rendered UI remains equivalent to the original**. Preserve original CSS until each route passes parity.
- Backend: Node.js 24 + Fastify + TypeScript.
- ORM: Prisma 7, with `@prisma/adapter-pg` and a generated client after database introspection.
- Data: existing Supabase PostgreSQL with existing SQL functions, RLS and transaction logic preserved. No fresh schema or new identities.
- Identity: Supabase Auth; Fastify authorizes tenant/project/staff access. Existing portal sessions and app-specific SSO must stay compatible.
- Shared contracts: typed interfaces, Zod where applicable, OpenAPI contract checks before swapping clients.
- Packages: npm workspaces and a committed lockfile (not created yet).
- Tests: Vitest + Playwright + isolated PostgreSQL and negative authorization tests.
- Deployment: Docker Compose on Hostinger VPS, Caddy behind Cloudflare, separate workers.
- Architecture: modular monolith; Next.js may render pages but Fastify owns authoritative business APIs.

No Express, Vite, new UI, Redis, Kafka, Kubernetes, microservice split, or database reset in the approved target.

Sources: original `3b3a1535873aa0517aea41da32a407f3d9680547`; business-approved migration decisions of November 12, 2026.
