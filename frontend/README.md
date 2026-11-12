# Frontend migration status

Next.js App Router + TypeScript scaffold only. It deliberately renders no product UI. Do not mistake a successful Next.js build for frontend feature parity.

The legacy split login and other screen CSS are copied into `docs/reference/styles/` for exact comparison; the original Inter font binary and per-page screenshots still need a controlled migration. Preserve the exact screen markup, text, spacing, states, colors and responsive breakpoints.

- `src/app/layout.tsx`: root Next.js layout
- `src/app/page.tsx`: intentionally blank until first route passes visual and behavior checks
- Future pages: `src/app/login/page.tsx`, `src/app/dashboard/page.tsx`, etc., only after parity evidence exists

No sensitive Supabase key may be exposed in Next.js client code or in a `NEXT_PUBLIC_*` environment variable.
