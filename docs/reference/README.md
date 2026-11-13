# Frozen visual references

All source references below were copied from the original VSPH Control Center commit `3b3a1535873aa0517aea41da32a407f3d9680547`:

- `DESIGN.md` (repository root)
- `styles/auth.css`, `styles/crm-auth.css`, and `styles/fonts.css`
- `views/auth.html`, `scripts/auth-page.js`, and `scripts/auth-config.js`
- **Original binary:** `../../frontend/public/fonts/inter-5a8d3e72.woff2`
- **Original reference screenshots:** `screenshots/login-desktop.jpg` and `screenshots/login-mobile.jpg`
- `fonts/INTER-LICENSE.txt` (SIL OFL licensing preserved)

The React login uses the **exact original CSS** and original Inter font bytes. Source blob SHA-1 checks are recorded in `tests/source-assets.test.mjs`. The GitHub blob IDs were compared against the original repository during the copy process.

**This is source preservation, not proof of identical rendering.** Screenshots may have been captured in different environments and are not yet reproducible pixel-baselines. Visual comparison in fixed Chromium versions/viewports/data, and authenticated use-case validation, are still required. CSS may not be reset by Tailwind or shadcn defaults.

## Next.js-specific font loading

The frozen `docs/reference/styles/auth.css` keeps its original `@import url('/fonts.css');` line. Next.js Turbopack treats this root-absolute CSS import as a build-time module and fails to resolve it. The actively compiled `frontend/src/app/auth.css` omits **only this first line**. `frontend/src/app/layout.tsx` loads the unchanged public `/fonts.css` as a normal stylesheet link. The original Inter WOFF2 binary and every other CSS declaration remain unchanged. Source-parity tests explicitly constrain this one packaging exception. Rendered pixel parity must still be confirmed.
