'use client';

import { useEffect, useState, type FormEvent } from 'react';
import {
  DEFAULT_AUTH_COPY,
  type ApplicationContext,
  type LoginResult,
  type MfaFactor,
  type OrganizationContext,
} from './presentation';

type ApiError = Error & { code?: string; factors?: MfaFactor[] };
type AuthPageProps = { appCode?: string };

async function requestLogin(endpoint: string, payload: Record<string, string>) {
  const response = await fetch(endpoint, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    credentials: 'same-origin',
    body: JSON.stringify(payload),
  });

  const body = (await response.json().catch(() => ({}))) as LoginResult;
  if (!response.ok) {
    const error = new Error(body.message || 'Unable to sign in. Please try again.') as ApiError;
    error.code = body.code;
    error.factors = body.factors;
    throw error;
  }
  return body;
}

/** Structure, IDs, accessibility attributes and copy mirror views/auth.html.
 * Exact source CSS is imported globally; shadcn/Tailwind must not restyle it.
 * Server-authenticated page gating is NOT migrated; do not deploy to users.
 */
export function AuthPage({ appCode }: AuthPageProps) {
  const isApplicationLogin = Boolean(appCode);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const [totpCode, setTotpCode] = useState('');
  const [totpFactorId, setTotpFactorId] = useState('');
  const [mfaVisible, setMfaVisible] = useState(false);
  const [factors, setFactors] = useState<MfaFactor[]>([]);
  const [organizations, setOrganizations] = useState<OrganizationContext[]>([]);
  const [organizationId, setOrganizationId] = useState('');
  const [applicationName, setApplicationName] = useState('');
  const [contextReady, setContextReady] = useState(!isApplicationLogin);
  const [busy, setBusy] = useState(false);
  const [errorMessage, setErrorMessage] = useState('');
  const copy = DEFAULT_AUTH_COPY;

  useEffect(() => {
    document.body.classList.toggle('app-auth', isApplicationLogin);
    document.body.dataset.authLayout = 'split';
    document.body.style.setProperty('--auth-bg', copy.background);
    document.body.style.setProperty('--auth-action', copy.action);
    document.body.style.setProperty('--auth-highlight', copy.highlight);

    return () => {
      document.body.classList.remove('app-auth');
      delete document.body.dataset.authLayout;
      document.body.style.removeProperty('--auth-bg');
      document.body.style.removeProperty('--auth-action');
      document.body.style.removeProperty('--auth-highlight');
    };
  }, [copy, isApplicationLogin]);

  useEffect(() => {
    if (!appCode) return;
    let active = true;
    setContextReady(false);
    setErrorMessage('');
    setOrganizations([]);
    setOrganizationId('');

    // The old Express page independently gated the page route. That control
    // must be ported to Fastify before application login goes live.
    async function loadContext() {
      try {
        const response = await fetch('/api/apps/' + encodeURIComponent((appCode ?? '')) + '/contexts', {
          credentials: 'same-origin',
        });
        if (!active) return;
        if (response.status === 401) {
          window.location.replace('/login');
          return;
        }
        const data = (await response.json().catch(() => ({}))) as
          Partial<ApplicationContext> & { message?: string };
        if (!response.ok) throw new Error(data.message || 'Unable to load this application.');
        if (!Array.isArray(data.organizations) || !data.organizations.length)
          throw new Error('Your account is not assigned to this application.');
        if (!data.application || typeof data.application.name !== 'string' ||
            typeof data.email !== 'string') {
          throw new Error('Unable to load this application.');
        }
        if (!active) return;
        setOrganizations(data.organizations);
        setOrganizationId((data.organizations[0]?.id ?? ''));
        setApplicationName(data.application.name);
        setEmail(data.email);
        setContextReady(true);
        document.title = data.application.name + ' sign in | VSPH Control Center';
      } catch (error) {
        if (active) setErrorMessage(
          error instanceof Error ? error.message : 'Could not load application access.',
        );
      }
    }
    void loadContext();
    return () => { active = false; };
  }, [appCode]);

  async function submitForm(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (busy || !contextReady) return;
    setErrorMessage('');
    setBusy(true);

    try {
      const payload: Record<string, string> = {
        email: isApplicationLogin ? email : email.trim(),
        password,
        ...(totpCode ? { totpCode, totpFactorId } : {}),
      };
      if (isApplicationLogin) {
        payload.app = (appCode ?? '');
        payload.organizationId = organizationId;
      }
      const data = await requestLogin(
        isApplicationLogin ? '/api/auth/app-login' : '/api/auth/login',
        payload,
      );
      if (isApplicationLogin) {
        // Back-end response must be same-origin and validated against the
        // permitted application. Original server returns /apps/CODE/home.
        const expected = '/apps/' + (appCode ?? '').toLowerCase() + '/home';
        if (data.redirect !== expected) throw new Error('Unexpected application destination.');
        window.location.assign(data.redirect);
      } else {
        window.location.assign(
          data.passwordChangeRequired === true ? '/employee-password' : '/dashboard',
        );
      }
    } catch (error) {
      const problem = error as ApiError;
      if (problem.code === 'MFA_REQUIRED' && Array.isArray(problem.factors)) {
        setFactors(problem.factors);
        setTotpFactorId(problem.factors[0]?.id ?? '');
        setMfaVisible(true);
        requestAnimationFrame(() => {
          document.getElementById('totpCode')?.focus();
        });
      }
      setErrorMessage(problem.message || 'Cannot connect. Please try again.');
    } finally {
      setBusy(false);
      setTotpCode('');
    }
  }

  const description = isApplicationLogin
    ? applicationName
      ? 'Confirm your password to enter ' + applicationName + '.'
      : 'Confirm your password to open the application.'
    : copy.formDescription;

  return (
    <>
      <div className="auth-shade" aria-hidden="true" />
      <div className="auth-layout">
        <header className="auth-header">
          <a className="brand-text" href="/" aria-label="VSPH Control Center">VSPH</a>
          <a id="backLink" className="auth-back" href="/dashboard" hidden={!isApplicationLogin}>
            ← Back to dashboard
          </a>
        </header>
        <main className="auth-main">
          <section className="auth-intro" aria-label="About VSPH">
            <div className="intro-kicker" id="heroKicker">{copy.heroKicker}</div>
            <h1>
              <span id="heroLineOne">{copy.heroLineOne}</span><br />{' '}
              <span id="heroLineTwo">{copy.heroLineTwo}</span>
              <span className="brand-period">.</span>
            </h1>
            <p id="heroDescription">{copy.heroDescription}</p>
            <ul className="auth-intro-features">
              <li><span aria-hidden="true">01</span>Customer and product management</li>
              <li><span aria-hidden="true">02</span>Projects, teams and delivery</li>
              <li><span aria-hidden="true">03</span>Secure access for every organization</li>
            </ul>
          </section>
          <section className="auth-card" aria-labelledby="authHeading">
            <div className="card-kicker" id="cardKicker">{copy.cardKicker}</div>
            <h2 id="authHeading">{copy.formHeading}</h2>
            <p className="form-description" id="formDescription">{description}</p>
            <form id="authForm" className="auth-form" method="post"
              action={isApplicationLogin ? '/api/auth/app-login' : '/api/auth/login'}
              onSubmit={(event) => void submitForm(event)}>
              <label htmlFor="email">Work email</label>
              <input id="email" name="email" type="email" autoComplete="username"
                inputMode="email" maxLength={254}
                placeholder={isApplicationLogin ? 'Work email' : 'name@company.com'}
                required autoFocus={!isApplicationLogin} readOnly={isApplicationLogin}
                value={email} onChange={(event) => setEmail(event.target.value)} />

              <div id="organizationField" className="organization-field"
                hidden={!isApplicationLogin}>
                <label htmlFor="organizationId">Customer organization</label>
                <select id="organizationId" name="organizationId"
                  value={organizationId} onChange={(event) => setOrganizationId(event.target.value)}
                  required={isApplicationLogin} disabled={!contextReady}>
                  {organizations.length === 0 &&
                    <option value="">Loading organizations…</option>}
                  {organizations.map((org) => (
                    <option key={org.id} value={org.id}>
                      {org.name + ' (' + String(org.role || 'user').replaceAll('_', ' ') + ')'}
                    </option>
                  ))}
                </select>
              </div>

              <label htmlFor="password">Password</label>
              <div className="password-field">
                <input id="password" name="password" type={showPassword ? 'text' : 'password'}
                  autoComplete="current-password"
                  placeholder={isApplicationLogin ? 'Confirm your password' : 'Enter your password'}
                  required value={password} onChange={(event) => setPassword(event.target.value)} />
                <button type="button" className="reveal" data-password-toggle="password"
                  aria-label={showPassword ? 'Hide password' : 'Show password'}
                  aria-controls="password" aria-pressed={showPassword}
                  onClick={() => setShowPassword((current) => !current)}>
                  <svg data-icon="show" viewBox="0 0 24 24" width="20" height="20"
                    fill="none" stroke="currentColor" strokeWidth="2"
                    aria-hidden="true"
                    strokeLinecap="round" strokeLinejoin="round"
                    style={{ display: showPassword ? 'none' : undefined }}>
                    <path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12Z"/>
                    <circle cx="12" cy="12" r="3"/>
                  </svg>
                  <svg data-icon="hide" viewBox="0 0 24 24" width="20" height="20"
                    fill="none" stroke="currentColor" strokeWidth="2"
                    aria-hidden="true"
                    strokeLinecap="round" strokeLinejoin="round"
                    style={{ display: !showPassword ? 'none' : undefined }}>
                    <path d="M10.6 5.1A10.7 10.7 0 0 1 12 5c6.5 0 10 7 10 7a15.3 15.3 0 0 1-3.2 4.1M6.3 6.3A15.6 15.6 0 0 0 2 12s3.5 7 10 7c1.7 0 3.2-.5 4.4-1.2"/>
                    <path d="m3 3 18 18"/>
                    <path d="M9.9 9.9a3 3 0 0 0 4.2 4.2"/>
                  </svg>
                </button>
              </div>

              <div id="mfaField" className="organization-field" hidden={!mfaVisible}>
                <label htmlFor="totpCode">Authenticator code</label>
                <input id="totpCode" name="totpCode" type="text"
                  inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}"
                  maxLength={6} aria-describedby="mfaDescription"
                  required={mfaVisible} value={totpCode}
                  onChange={(event) => setTotpCode(event.target.value)} />
                <p id="mfaDescription" className="form-description">
                  Use the current six-digit code from your enrolled authenticator.
                </p>
                <div id="mfaFactorField" className="organization-field"
                  hidden={factors.length <= 1}>
                  <label htmlFor="totpFactorId">Authenticator</label>
                  <select id="totpFactorId" name="totpFactorId" value={totpFactorId}
                    onChange={(event) => setTotpFactorId(event.target.value)}>
                    {factors.map((factor) => (
                      <option key={factor.id} value={factor.id}>{factor.name}</option>
                    ))}
                  </select>
                </div>
              </div>

              <p id="authError" className="form-error" role="alert" aria-live="polite"
                hidden={!errorMessage}>{errorMessage}</p>
              <button id="authSubmit" className="auth-submit" type="submit"
                disabled={busy || !contextReady}>
                <span className="submit-label">
                  {busy ? (isApplicationLogin ? 'Verifying access…' : 'Signing in…') : 'Sign in'}
                </span>
              </button>
            </form>
            <div id="inviteEntry" className="invite-entry" hidden={isApplicationLogin}>
              <span>Invited to VSPH?</span>
              <a href="/accept-invite">How to activate your account</a>
            </div>
          </section>
        </main>
        <footer className="auth-footer">
          <span>© 2026 VSPH. All rights reserved.</span>
        </footer>
      </div>
    </>
  );
}
