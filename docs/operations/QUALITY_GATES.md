# Quality and release gates

- [ ] Commit reviewed npm lockfile, check installed versions and run npm CI against Node 24
- [ ] TypeScript strict type check and ESLint/Prettier pass
- [ ] Fastify readiness/security tests pass (not executed in foundation commit)
- [ ] Prisma is introspected on approved restored staging, not production
- [ ] All legacy endpoints and roles have parity tests (positive + negative)
- [ ] Screenshots compared for each page and state with fixed device/font/browser configuration
- [x] Legacy Inter binary and login screenshot assets copied byte-identically, with license; [ ] rendered appearance verified
- [ ] SQL migration manifest reconciled and cross-tenant/financial tests pass
- [ ] Live auth/session revocation, SMTP/invitations, Music/Outreach SSO and GitHub integrations accepted
- [ ] Backup and independent restore verified, production owner approves release
- [ ] Staging deployment and independent cutover/rollback rehearsed

**Current status:** Login UI and exact original assets are merged. Draft PR #7 includes authentication/session/entitlement business rules and HTTP security hooks, with synthetic tests written but not run. CI, browser, Docker, real session issuance, staging Auth and hosted acceptance remain unverified. No production database or DNS mutation.
