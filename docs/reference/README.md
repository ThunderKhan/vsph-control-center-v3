# Frozen visual references

Exact text files copied from `3b3a1535873aa0517aea41da32a407f3d9680547`: root `DESIGN.md`, `styles/auth.css`, `styles/crm-auth.css`, `styles/fonts.css`, `views/auth.html`, `scripts/auth-page.js`, `scripts/auth-config.js`.

For active React work, `frontend/src/app/auth.css` and `crm-auth.css` are byte-for-byte copies of original stylesheet text; they must not be replaced with Tailwind defaults or new branding.

The original `public/fonts/inter-5a8d3e72.woff2` binary cannot currently be read by the GitHub text connector and has **not** been copied; preserve its SIL license and original bytes during a source checkout. Until available, the new login cannot be accepted as a pixel-identical replacement.

Original screenshots remain at `docs/screenshots/login-desktop.jpg` and `login-mobile.jpg` in the original repository.

Do not recreate typography from memory or claim visual parity without fixed screenshot comparisons.
