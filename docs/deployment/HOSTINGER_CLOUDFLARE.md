# Deployment design — not deployed

Target: Hostinger **VPS**, not ordinary managed/shared hosting, because Next.js and Fastify need Node processes and the system requires Docker and durable workers.

Proposed edge: `app.vsph.in` proxied through Cloudflare with Full (strict) TLS; Caddy on the VPS terminates origin TLS and routes `/api/*` to Fastify and all other routes to Next.js. PostgreSQL and Supabase Auth stay in Supabase Cloud.

Planned services: Next.js standalone Node server; Fastify Node server (not publicly bound); separately supervised workers; Caddy; health and monitoring.

**No Dockerfile/Compose file is released yet**: the package lock, access controls, exact upstream ports, certificates, privileged DB role, worker identities, and real app readiness must be reviewed before executable production packaging.

Never deploy the foundation as a replacement: it renders no actual application and deliberately returns HTTP 503 on health and login.

Before cutover: staging parity, isolated database test, verified encrypted offsite backup/restore, monitoring, documented rollback and operator sign-off.
