# First login interface port — NOT YET PARITY-CERTIFIED

Source: original `3b3a1535873aa0517aea41da32a407f3d9680547`.

## Scope in the proposed PR

- Added Next.js `/login` and `/apps/[app]/login` pages.
- Converted exact legacy markup (IDs, copy, input labels, split layout, password visibility, MFA, application-organization selector) to typed React state and event handlers.
- Imported exact original `public/auth.css` and `public/crm-auth.css`, unchanged, into the frontend.
- Added legacy `public/fonts.css`, plus archived original HTML and JavaScript controller.
- Added structural Playwright tests for copy, controls, failed sign-in, MFA, app-context denial at desktop/mobile.

## Known incomplete

1. **No working server-side session gating or Supabase Auth is ported.** The Fastify `/api/auth/login` endpoint still intentionally returns 503, and app context APIs do not exist. Do not deploy these pages to customers, enable live login, or claim working authentication.
2. **The exact original Inter `.woff2` is now copied** with a matching GitHub blob SHA. Original login screenshots are also archived in `docs/reference/screenshots/`. This closes the source-asset gap, but does not verify pixel-level visual parity.
3. Original per-page screenshots have not been captured with matching browser, data, DPI and viewport. Structural tests are NOT pixel comparisons.
4. Next.js routing has not yet implemented the legacy pre-render session redirect for a valid portal cookie. Root `/`, `/dashboard` and `/employee-password` remain unmigrated.
5. Design override registry currently uses the original unchanged base theme only; product/customer overrides and any server-provided presentation configuration need porting when integrating backend.
6. The auth-only root body class must be scoped before any non-auth pages are introduced.
7. Dependencies are not installed; lockfile, full TypeScript/build/browser tests have not run.

## Before this can be accepted

- [x] Copy exact original font and baseline screenshot assets (source blob SHAs verified).
- [ ] Capture a controlled, reproducible set of source-vs-target screenshots.
- Compare screenshot baselines of original and port for desktop, tablet and mobile.
- Port and test safe Fastify session, profile, temporary-credential, MFA, origin validation, rate limits, and app-context checks.
- Run native Playwright tests against an isolated mock backend, then authorized real staging Auth tests.
- Update `docs/migration/TRACEABILITY.md` with actual evidence rather than declaring completion.

The source and production Supabase database remain unchanged.
