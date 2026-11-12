# VSPH — Design System

## Overview
VSPH is an enterprise software partner ("Enterprise software. Practical
thinking. Human impact.") building web, mobile, and custom applications
for organizations that want to streamline work and prepare for growth.
Visual design should feel **professional, trustworthy, precise, and
forward-looking — never loud, playful, or decorative for its own sake.**

Guiding principles:
- Structure meets possibility: a disciplined grid and restrained palette,
  with the "V" motif and ascending-pixel detail as the only expressive flourish.
- Color should clarify, not compete — neutrals carry most of the page; navy
  and blue are used with intent, not decoration.
- One signature, clear hierarchy — never invent new logo lockups or stack
  every brand message into one small composition.

<!-- Source note: extracted from VSPH Brand Guidelines v1.0 (Sept 2026). The
company name, core messages, palette, and Inter typeface are stated as
verified brand facts in that document. Strategy language, layout rules, and
component specs were marked in the source as "proposed standards for
adoption" — carried into this file and flagged below where relevant. -->

## Color System
Semantic name first, hex in parentheses, then when to use it.

**Brand**
- `brand-navy` (#00255A) — primary brand color; trust, depth, enterprise
  confidence. Used for headlines, hierarchy, dark section/cover backgrounds.
- `brand-core-blue` (#0069C8) — action, innovation, technology. Reserve for
  primary actions/links — the thing the user can act on, not decoration.
- `brand-light-blue` (#50C0E8) — progress, openness, digital energy. Use
  for selective accents only (see 5% usage guidance below).

**Neutrals**
- `neutral-white` (#FFFFFF) — space, clarity, clean foundation; default
  page/document background.
- `neutral-black` (#000000) — single-color reproduction and utility only
  (e.g. one-ink print, monochrome logo master). Not a general text color.
- `neutral-grey` (#F1F2F2) — quiet surfaces, card backgrounds, visual
  organization.

**Suggested balance for content layouts**
- 60% neutrals (white/grey) · 25% navy · 10% core blue · 5% light blue.
  Covers and section-divider pages may use a dominant navy or blue field
  instead of this ratio.

**Verified contrast pairings (meet WCAG normal-text threshold)**
- White on navy — 14.87:1
- White on core blue — 5.45:1
- Navy on light blue — 7.11:1
- Core blue on grey — 4.86:1

**Avoid for meaningful text**
- White on light blue (2.09:1) → use navy on light blue instead.
- Core blue on navy (2.73:1) → use white or light blue on navy instead.

Digital source of truth is the exact sRGB/HEX values above. For print,
convert through the printer's ICC profile and approve a physical proof —
no CMYK/Pantone equivalents are verified in the source brand guidelines.
Never use color alone to communicate status.

## Typography
- **Font family**: Inter (weights 300–700). Fallback stack: `Inter, Arial,
  sans-serif` — use the fallback only where Inter can't be embedded/installed.
- **Type scale** (digital, size/line-height in px, then weight):
  - H1: 60/72, 700 — one clear entry point per layout.
  - H2: 40/52, 600
  - H3: 28/36, 600
  - H4: 20/28, 500
  - Body: 18/28, 400
  - Support/label: 14/20, 400
- **Responsive**: on small screens reduce H1 to 36/44 and keep body text at
  16/24 or larger.
- **Print (A4 documents)**: start with 28–36pt headings and 10.5–12pt body
  copy; verify the printed reading size.
- **Weight conventions**: Regular (400) for body copy, Medium (500) for
  labels, Semibold (600) for supporting headings, Bold (700) reserved for
  strong emphasis/H1. Reserve Light (300) for large display text only —
  never for small labels, body paragraphs, or reverse (light-on-dark) text.
- **Case & alignment**: sentence case for ordinary headings; paragraphs
  left-aligned, 45–75 characters per line.

## Spacing & Layout
- **Base unit / scale**: 8px spacing rhythm — 8, 16, 24, 32, 48, 64px. Use
  4px only for small optical adjustments.
- **Grid**: 12-column grid for desktop; 4-column grid with 20–24px side
  margins for mobile.
- **Alignment**: one consistent left edge; align headings, images, and
  captions to shared edges. Build one strong focal point per layout with
  generous open space around it; separate ideas with white space before
  adding boxes, dividers, or decorative effects.
- **Print starting point**: landscape A4, ~15mm outer margins; a 1:2
  guidance-to-demonstration split when a rule needs a visual example.

## Iconography & Imagery
**Icons** <!-- proposed, not yet confirmed against a production icon set -->
- Outline style, rounded ends, consistent optical weight.
- Construction: 24×24px base grid, 2px stroke at base size, consistent
  corner treatment, core-blue (#0069C8) on light backgrounds.
- Pair unfamiliar symbols with text labels; keep decorative icons out of
  the accessibility reading order and label controls by function.
- Never mix filled, outlined, 3D, and multicolor icon styles in one
  composition.

**Photography**
- Style: candid collaboration, attentive interaction, believable business
  environments, natural skin tones ("human"); software shown in real work
  contexts with clean, accurate interfaces and no sensitive information
  visible ("purposeful"); architecture/infrastructure used to suggest
  ambition, with calm compositions and a restrained blue grade
  ("forward-looking").
- Avoid: staged handshakes, generic glowing globes, sci-fi effects, and
  imagery implying unverified client relationships. Secure usage rights
  and permissions for any production photography.

**Progress-lines motif** <!-- proposed supporting graphic system, not a verified brand asset -->
- Fine angular paths with a small rhythm of ascending square details,
  inspired by the V symbol. A supporting device, not a second logo.
- Use a single direction of movement, keep strokes light, limit detail to
  one area of a composition, keep text on a quiet field.
- Never turn the motif into a replacement logo or scatter pixels around
  body copy; never let it carry essential information — decoration only.

## Logo Usage
- **Primary lockup**: horizontal signature — angular "V" symbol + VSPH
  wordmark, kept in their original relationship. Treat the complete lockup
  as one piece of artwork; never recreate the wordmark in another font,
  attach new text to it, or invent additional lockups.
- **Standalone V symbol**: for compact spaces where the VSPH name is
  already established (e.g. an avatar or app launcher).
- **Backgrounds**: primary (full color) on light backgrounds/documents;
  reversed (white) on navy for covers/dark environments; monochrome
  black for single-color reproduction; monochrome navy for light-blue
  fields or restricted production. Always choose the version that
  preserves the full silhouette and keeps "VSPH" immediately readable.
- **Clear space**: let `x` = height of the main V body (excluding the
  ascending pixels); keep at least `x` clear on every side of the logo's
  outer bounds. Text, images, borders, and page edges must stay outside
  this area.
- **Minimum size**: horizontal signature 140px / 35mm wide; standalone
  symbol 40px / 10mm high (use a separately approved small-size asset
  below this).
- **Never**: stretch/compress the artwork, rotate it, introduce arbitrary
  logo colors, place it on busy backgrounds, or add shadows/outlines/effects.

## Components
<!-- proposed, not yet confirmed against a production component library -->

**Buttons**
- Primary: filled core-blue (#0069C8) background, white text — for the
  main action per view (e.g. "Discuss your project").
- Secondary: outlined, navy border/text on light backgrounds, or white
  outline/text on navy.
- Minimum interaction target: 44×44px.

**Cards**
- Background: grey (#F1F2F2) for light-context cards, or navy (#00255A)
  for emphasis cards on light pages. No drop shadows — flat fields only.

**Navigation**
- Simple, need-based grouping; one clear next step (primary CTA) per
  section. Visible keyboard focus required on all interactive elements.

**Forms / inputs**
- Pair errors with helpful, specific text (e.g. "Enter a valid email
  address to continue" — never generic messages like "Invalid input").

## Messaging Hierarchy
- **Brand headline** (exact wording, preserve capitalization): "Building
  What's Next."
- **Company descriptor**: "Enterprise Software Solutions for a Smarter
  Tomorrow."
- **Supporting statement**: "Building scalable digital solutions."
- **Brand signature**: "People | Products | Possibilities"
- Lead with the core message, then the most relevant capability/business
  context, then close with a useful action (e.g. "Discuss your project.
  Explore our services."). Set messages as live type in the layout — do
  not attach new text to the logo.

## Voice & Tone
- Professional, innovative, trustworthy, collaborative, human — precise
  and composed, forward-looking, honest about scope/evidence/limitations,
  open and respectful, written as one person helping another make progress.
- Prefer active verbs, short sentences, sentence case; explain unfamiliar
  abbreviations on first use.
- Write "VSPH" in capitals; keep product/service labels clear and descriptive.
- Use client names, certifications, and performance results only when
  verified and approved — never invent results to strengthen a story.
- Tone can flex by context (more concise in interfaces, more explanatory
  in proposals, warmer in project communication) while the underlying
  voice stays consistent.
- Terminology: prefer plain language over jargon —
  - Use "We build software that helps your teams work better," not "We
    leverage cutting-edge solutions to revolutionize your business."
  - Use "Tell us what you want to build," not "Submit your requirements."

## Accessibility
- **Contrast**: minimum 4.5:1 for normal text, 3:1 for qualifying large
  text — test actual foreground/background pairs (see verified pairings
  under Color System); recheck gradients, overlays, and interaction states.
- **Focus states**: visible keyboard focus required; never rely on color
  alone to communicate status or state.
- **Touch targets**: 44×44px minimum on interactive elements.
- **Documents**: keep text selectable; verify reading order, document
  language, meaningful links, and image alternatives before final delivery.

## Do's and Don'ts
- Never stretch, compress, or rotate the logo artwork.
- Never introduce arbitrary logo colors or place the logo on busy backgrounds.
- Never recreate the VSPH wordmark in another font or invent new lockups.
- Never use color as the only way to communicate status.
- Never use white text on light-blue backgrounds, or core-blue text on
  navy backgrounds — both fail contrast.
- Never scatter the progress-lines/pixel motif around body copy or treat
  it as a second logo.
- Never mix filled, outlined, 3D, and multicolor icon styles in one composition.
- Always pair an unfamiliar icon with a text label.
- Always give error messages specific, helpful text rather than generic
  messages like "Invalid input."
- Always use verified claims, client names, and figures — never invented
  results.

## Changelog
- 2026-09-22: Initial DESIGN.md drafted from VSPH Brand Guidelines v1.0
  (September 2026). Color, typography (Inter), core messaging, and logo
  usage rules are stated as verified in the source; component specs,
  icon construction, and the progress-lines motif were marked "proposed"
  in the source and carried here flagged as such.