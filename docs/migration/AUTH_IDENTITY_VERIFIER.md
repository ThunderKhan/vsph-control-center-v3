# Supabase identity-verifier port (source-only, not wired to HTTP)

Frozen source: `services/verify-identity.js` at `3b3a1535873aa0517aea41da32a407f3d9680547`.

This change ports:
- Credential normalization, validation lengths (email <=254, password <=4096), UUID factor identifiers, TOTP format and error codes.
- Per-attempt isolated Supabase Auth clients (no shared in-memory login).
- Password verification and immediate confirmation of the authenticated user.
- MFA assurance-level check, verified TOTP factor filtering, challenge/verify and post-MFA identity proof.
- Local-only provider sign-out on every successful provider session, including failed MFA flows. Other sessions are not globally revoked.
- Provider outage and error mapping that fails closed, without revealing sensitive login details.
- Isolated unit tests using fake provider responses; no live auth or user accounts.

**Not yet implemented:** HTTP Fastify integration, rate limits, cookies and database-backed portal sessions, temporary employee credentials, Prisma models, MFA-factor enrollment, application product contexts, login page preauthorization and real Supabase staging acceptance. `backend/src/app.ts` remains a 503 fail-closed scaffold. This change intentionally cannot sign a person into Control Center.

Before wiring the authenticator into login, make database access safe through a reviewed restored staging schema, preserve session hash/cookie behavior and account-disable checks, verify CSRF origin, rate limits, tenant authorization and temporary-password redemption. Do not turn a successfully verified password into an active session without these checks.

The repository remains public; no credentials or production data were touched. Dependencies cannot currently be installed in this environment; the added TypeScript tests must be run before this module is accepted.
