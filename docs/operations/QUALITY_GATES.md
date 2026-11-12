# Quality and release gates

- [ ] Commit reviewed npm lockfile, check installed versions and run npm CI against Node 24
- [ ] TypeScript strict type check and ESLint/Prettier pass
- [ ] Fastify readiness/security tests pass (not executed in foundation commit)
- [ ] Prisma is introspected on approved restored staging, not production
- [ ] All legacy endpoints and roles have parity tests (positive + negative)
- [ ] Screenshots compared for each page and state with fixed device/font/browser configuration
- [x] Legacy Inter binary and login screenshot assets copied byte-identically, with license; [ ] rendered appearance verified
- [x] Frozen source SQL and migration manifest copied byte-identically (40 Git blobs); [ ] local SHA-256 source tests and real target catalog/role/finance checks passed
- [ ] Live auth/session revocation, SMTP/invitations, Music/Outreach SSO and GitHub integrations accepted
- [ ] Backup and independent restore verified, production owner approves release
- [ ] Staging deployment and independent cutover/rollback rehearsed

**Current status:** Login UI and exact original assets are merged. Merged PR #7 includes authentication/session/entitlement business rules and HTTP security hooks, with synthetic tests written but not run. PR #8 added manual Node 24 build verification, but no npm lockfile/build pass yet. Draft PR #10 includes optional isolated portal HTTP contracts with fake stores; normal Fastify startup still fails closed. CI, browser, Docker, real session issuance, staging Auth and hosted acceptance remain unverified. No production database or DNS mutation.
