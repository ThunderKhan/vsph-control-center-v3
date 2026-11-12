# Portal login business logic — staged port, not activated

The `backend/src/modules/auth/portal-login.ts` module ports the original `routes/auth.js` portal sign-in behavior into a testable TypeScript orchestration layer. All database operations are injected through a `PortalLoginStore` interface. **No real store adapter or HTTP route activation exists.**

Preserved legacy behavior:
- Normalize email and preserve raw password characters.
- Require complete credentials before contacting the Auth provider.
- Verify Supabase identity/MFA before checking the current **active** internal profile.
- Invoke temporary employee-session revocation after identity verification.
- Never issue an active portal cookie for missing/disabled/mismatched identities.
- Support the employee temporary-password handoff **only if** the real SQL-backed enrollment RPC authorizes it, not from user metadata alone.
- Persist SHA-256 of a new opaque token with four-hour expiry before returning a cookie instruction.
- Maintain original JSON field names and cookie names/expiry for legitimate sessions.

Security constraints:
- No Prisma model has been invented or deployed; original SQL schema, RLS functions and session tables remain canonical.
- Production Fastify `/api/auth/login` stays fail-closed at HTTP 503.
- Cookie instructions are returned as data; a future trusted HTTP adapter must emit Secure, HttpOnly, SameSite=Lax, path=/ with the original max ages.
- A real `PortalLoginStore` must preserve transaction error behavior, SQL grants, temporary credential nonce and replay protections, account disabling and revocation.
- The isolated Vitest tests are written but cannot be claimed passing until dependencies are installed and `npm run test` is executed.

Next: implement read-only session/profile store against a verified isolated staging restore, then complete Fastify HTTP routes and original application-specific login/Outreach SSO paths.

## Fastify HTTP adapter (isolated synthetic tests only)

`login-http.ts` implements original `POST /api/auth/login` response codes, MFA error bodies, cookie attributes and the no-cookie-on-failure rule. `buildApp({ login: testDependencies })` lets unit tests use a synthetic store, while the actual `backend/src/server.ts` calls `buildApp()` without adapters and **continues returning 503**.

Live HTTP use additionally requires the original portal-session store schema, staging approval, exact Origin/reverse-proxy policy, rate-limit validation and release approval. The HTTP tests are written but not yet executed in an installed dependency environment.
