# Quality and release gates

- [ ] Commit reviewed npm lockfile, check installed versions and run npm CI against Node 24
- [ ] TypeScript strict type check and ESLint/Prettier pass
- [ ] Fastify readiness/security tests pass (not executed in foundation commit)
- [ ] Prisma is introspected on approved restored staging, not production
- [ ] All legacy endpoints and roles have parity tests (positive + negative)
- [ ] Screenshots compared for each page and state with fixed device/font/browser configuration
- [ ] Legacy Inter binary and assets copied with license and verified appearance
- [ ] SQL migration manifest reconciled and cross-tenant/financial tests pass
- [ ] Live auth/session revocation, SMTP/invitations, Music/Outreach SSO and GitHub integrations accepted
- [ ] Backup and independent restore verified, production owner approves release
- [ ] Staging deployment and independent cutover/rollback rehearsed

**Current status:** only scaffold and written contract exist. No CI, browser, Docker or hosted acceptance has run. No production database or DNS mutation.
