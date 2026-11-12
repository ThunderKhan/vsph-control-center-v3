# Legacy-to-v3 traceability

No entry is accepted or done until source, new path, original screenshot(s), contract tests, and negative authorization tests have been reviewed.

| Legacy source | v3 destination | Status |
| --- | --- | --- |
| `views/auth.html`, `public/auth*.js`, `public/auth.css`, `public/crm-auth.css` | `frontend/src/app/login/`, `frontend/src/app/apps/[app]/login/`, `frontend/src/features/auth/` | React UI source port merged; exact font/screenshots copied; **not accepted** (rendered visual parity, live server auth pending) |
| `public/portal-navigation.*`, `public/dashboard.*` | `frontend/src/components/`, `frontend/src/app/dashboard/` | Not ported |
| `routes/auth.js`, `security.js`, `services/verify-identity.js`, `access-policy.js`, `tokens.js`, `http-security.js` | `backend/src/modules/auth/`, `backend/src/http-security.ts` | Identity/MFA verification, session resolution, token utilities, product entitlements and security hooks merged in PR #7; live sessions and routes **not ported**, login 503 |
| `routes/employees.js`, `services/employee-*.js` | `backend/src/modules/employees/` and frontend employees | Not ported |
| `routes/hrms.js`, `routes/calendar.js` | `backend/src/modules/hrms/` and frontend HRMS | Not ported |
| `routes/projects.js`, `routes/delivery.js` | `backend/src/modules/projects/` and frontend projects | Not ported |
| `routes/finance.js`, `routes/finance-journal.js` | `backend/src/modules/finance/` and frontend finance | Not ported |
| `routes/organizations.js`, `routes/customers.js` | `backend/src/modules/organizations/` | Not ported |
| `routes/invitations.js`, `services/invitation-worker.js` | backend invitations + worker | Not ported |
| `routes/sso.js`, `routes/outreach-sso.js` | `backend/src/modules/integrations/` | Not ported |
| `services/workers/` and GitHub sync | `workers/` and backend integrations | Not ported |
| `supabase/migration-manifest.json`, `schema.sql`, 38 SQL migrations | `supabase/` frozen source archive | Byte-identical Git source blobs, read-only archive; **not executed**, Prisma model mapping still pending isolated staging |

Source revision: `3b3a1535873aa0517aea41da32a407f3d9680547`.
