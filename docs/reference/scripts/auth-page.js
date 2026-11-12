// The only login controller for the VSPH portal and every application.
// Presentation is shared; the authentication endpoints and sessions are not.
(() => {
  'use strict';

  const match = window.location.pathname.match(/^\/apps\/([a-z][a-z0-9_-]*)\/login\/?$/i);
  const appCode = match ? match[1].toUpperCase() : null;
  const isApplicationLogin = Boolean(appCode);
  const config = window.VSPH_AUTH_CONFIG || {};
  const byId = id => document.getElementById(id);

  const form = byId('authForm');
  const email = byId('email');
  const password = byId('password');
  const totpCode=byId('totpCode'),totpFactor=byId('totpFactorId');
  const organizationField = byId('organizationField');
  const organizationSelect = byId('organizationId');
  const submit = byId('authSubmit');
  const buttonLabel = submit.querySelector('.submit-label');
  const errorBox = byId('authError');
  const backLink = byId('backLink');
  const toggle = document.querySelector('[data-password-toggle="password"]');
  let application = null;

  function showError(message) {
    errorBox.textContent = message;
    errorBox.hidden = !message;
  }

  function appearance() {
    const product = (config.apps || {})[appCode] || {};
    const organizationKey = appCode + ':' + organizationSelect.value;
    const customer = isApplicationLogin && organizationSelect.value
      ? (config.organizations || {})[organizationKey] || {} : {};
    const theme = Object.assign({}, config.base || {}, product, customer);
    // Known layout variants only; never inject arbitrary HTML or CSS from a client setting.
    document.body.setAttribute('data-auth-layout', theme.layout === 'focused' ? 'focused' : 'split');

    const texts = [
      ['heroKicker', 'heroKicker'],
      ['heroLineOne', 'heroLineOne'],
      ['heroLineTwo', 'heroLineTwo'],
      ['heroDescription', 'heroDescription'],
      ['cardKicker', 'cardKicker'],
      ['authHeading', 'formHeading'],
      ['formDescription', 'formDescription']
    ];
    for (const [id, property] of texts) {
      if (typeof theme[property] === 'string') byId(id).textContent = theme[property];
    }

    // Default application heading is intentionally short and uses the same UI.
    if (isApplicationLogin && !('formDescription' in product) &&
        !('formDescription' in customer)) {
      byId('formDescription').textContent = application
        ? 'Confirm your password to enter ' + application.name + '.'
        : 'Confirm your password to open the application.';
    }

    for (const [property, variable] of [
      ['background', '--auth-bg'],
      ['action', '--auth-action'],
      ['highlight', '--auth-highlight']
    ]) {
      if (typeof theme[property] === 'string') document.body.style.setProperty(variable, theme[property]);
    }
  }

  function setBusy(busy, loadingText) {
    submit.disabled = busy;
    buttonLabel.textContent = busy ? loadingText : 'Sign in';
  }

  toggle.addEventListener('click', () => {
    const reveal = password.type === 'password';
    password.type = reveal ? 'text' : 'password';
    toggle.querySelector('[data-icon="show"]').hidden = reveal;
    toggle.querySelector('[data-icon="hide"]').hidden = !reveal;
    toggle.setAttribute('aria-label', reveal ? 'Hide password' : 'Show password');
    toggle.setAttribute('aria-pressed', String(reveal));
  });

  async function request(url, payload) {
    const response = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      body: JSON.stringify(payload)
    });
    const body = await response.json().catch(() => ({}));
    if (!response.ok){const error=new Error(body.message || 'Unable to sign in. Please try again.');error.code=body.code;error.factors=body.factors;throw error;}
    return body;
  }

  async function loadApplicationContext() {
    // The Express route already checks portal authentication + product access.
    // This API repeats the authorization check before enabling the form.
    try {
      const response = await fetch('/api/apps/' + encodeURIComponent(appCode) + '/contexts', {
        credentials: 'same-origin'
      });
      if (response.status === 401) {
        window.location.replace('/login');
        return;
      }
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(data.message || 'Unable to load this application.');
      if (!data.organizations || !data.organizations.length) {
        throw new Error('Your account is not assigned to this application.');
      }
      application = data.application;
      email.value = data.email;
      email.placeholder = 'Work email';

      organizationSelect.replaceChildren();
      for (const org of data.organizations) {
        const option = document.createElement('option');
        option.value = org.id;
        option.textContent = org.name + ' (' + String(org.role || 'user').replaceAll('_', ' ') + ')';
        organizationSelect.append(option);
      }
      organizationSelect.disabled = false;
      submit.disabled = false;
      document.title = application.name + ' sign in | VSPH Control Center';
      appearance();
    } catch (error) {
      showError(error.message || 'Could not load application access.');
    }
  }

  if (isApplicationLogin) {
    document.body.classList.add('app-auth');
    email.readOnly = true;
    email.removeAttribute('autofocus');
    password.placeholder = 'Confirm your password';
    organizationField.hidden = false;
    organizationSelect.required = true;
    organizationSelect.disabled = true;
    submit.disabled = true;
    backLink.hidden = false;
    organizationSelect.addEventListener('change', appearance);
    appearance();
    loadApplicationContext();
  } else {
    // The server has already checked the portal cookie before rendering.
    appearance();
    // Product-specific second-stage login does not advertise account onboarding.
    byId('inviteEntry').hidden = false;
  }

  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (submit.disabled) return;
    showError('');
    setBusy(true, isApplicationLogin ? 'Verifying access…' : 'Signing in…');

    try {
      if (isApplicationLogin) {
        const data = await request('/api/auth/app-login', {
          app: appCode,
          email: email.value,
          password: password.value,
          ...(totpCode.value?{totpCode:totpCode.value,totpFactorId:totpFactor.value}:{}),
          organizationId: organizationSelect.value
        });
        // Only the backend chooses the destination after a valid app-scoped login.
        window.location.assign(data.redirect);
      } else {
        const data=await request('/api/auth/login', {
          email: email.value.trim(),
          password: password.value,
          ...(totpCode.value?{totpCode:totpCode.value,totpFactorId:totpFactor.value}:{})
        });
        window.location.assign(data.passwordChangeRequired===true?'/employee-password':'/dashboard');
      }
    } catch (error) {
      if(error.code==='MFA_REQUIRED'&&Array.isArray(error.factors)){
        totpFactor.replaceChildren();
        for(const factor of error.factors){const option=document.createElement('option');option.value=factor.id;option.textContent=factor.name;totpFactor.append(option);}
        byId('mfaFactorField').hidden=error.factors.length<=1;byId('mfaField').hidden=false;totpCode.required=true;totpCode.focus();
      }
      showError(error.message || 'Cannot connect. Please try again.');
      setBusy(false);
    } finally {
      totpCode.value='';
    }
  });
})();
