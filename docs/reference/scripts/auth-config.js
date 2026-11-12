// Presentation only. Authorization remains entirely on the Express backend.
// All login views share views/auth.html, public/auth.css and public/auth-page.js.
// For a product or customer-specific look, override only the needed values below.
window.VSPH_AUTH_CONFIG = Object.freeze({
  base: {
    layout: 'split', // 'split' (VSPH default) or 'focused' (centered login)
    heroKicker: 'ENTERPRISE SOFTWARE',
    heroLineOne: 'Building',
    heroLineTwo: "What's Next",
    heroDescription: 'Enterprise Software Solutions for a Smarter Tomorrow.',
    cardKicker: 'VSPH CONTROL CENTER',
    formHeading: 'Welcome back',
    formDescription: 'Sign in to access your organization’s applications.',
    background: '#00255A',
    action: '#0069C8',
    highlight: '#50C0E8'
  },

  // An app overrides the base design only when it needs to.
  apps: {
    // CRM: { heroKicker: 'CRM WORKSPACE', formDescription: 'Sign in to CRM.' },
    // MUSIC: { heroKicker: 'MUSIC WORKSPACE' }
  },

  // Organization-specific overrides are keyed by "APP_CODE:ORGANIZATION_UUID".
  // They are applied only after the server has returned an authorized context.
  // For example: 'CRM:00000000-0000-0000-0000-000000000001': { action: '#0069C8' }
  organizations: {}
});
