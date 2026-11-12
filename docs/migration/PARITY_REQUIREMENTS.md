# Non-negotiable parity contract

**This project is a technology port, not a redesign.** All text, punctuation, sizes, font, colors, spacing, layout, buttons, table formatting, iconography, page positions, interactions, navigation, responsive behavior and page-specific states must match the frozen legacy reference.

## Acceptance

1. Capture trusted screenshots of *every* legacy page for desktop, tablet and mobile with the same fixed viewport, DPI, browser engine, time zone, font and fixture data.
2. Record empty, loading, populated, validation-error, success, unauthorized and disabled states wherever applicable.
3. Compare screenshots after porting, including typography baselines, line wrapping, scroll heights, header positions, spacing and responsive breakpoints.
4. Treat all non-trivial differences as defects. Any deliberate difference requires a documented user approval and an explicit source-vs-target delta.
5. Preserve exact wording and interaction behavior, including form field constraints, status messages, role-based navigation and stateful action outcomes.
6. Verify equivalent HTTP status codes, headers, JSON contracts, transactions, tenant access, session expiry/revocation and audit records with isolated tests.
7. Do not consider a page/function complete without both visual and functional acceptance.
8. Do not create a fake replacement dashboard, login, or sample statistics. Do not change client-facing copy merely to accommodate the new framework.

**Current status:** no migrated page or API passes these gates. The root page intentionally renders nothing; the Fastify server intentionally returns 503 until the authorized port is ready.

Rollback is not a cosmetic concern: keep the original application and its independent deploy path usable until v3 is production-accepted.
