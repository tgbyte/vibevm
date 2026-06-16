# vibevm — brand assets

Logo for **vibevm**, the throwaway KVM sandbox for vibe-coding with Claude in auto mode.

## The mark

`[∿]` — square-bracket **sandbox walls** enclosing a **wave** (the “vibe”). It reads
the project in one glyph: a contained, safe space where the agent does its thing.
It also nods to the terminal (brackets) and stays legible down to 16 px.

## Palette

| Token | Hex | Use |
| --- | --- | --- |
| Ink | `#0D1117` | Background / badge fill |
| Teal | `#2DD4BF` | The walls — containment / safety |
| Coral | `#FF7A5C` | The wave — the “vibe” / activity |
| Muted | `#8B98A5` | Secondary text / taglines |
| Edge | `#212B35` | Hairline border on the dark badge |

Wordmark: `vibe` in coral + `vm` in teal, monospace, lowercase.

## Files

| File | Use |
| --- | --- |
| `logo-mark.svg` | Primary mark, transparent. Works on light and dark. |
| `logo-badge.svg` | Mark on the dark rounded square — app icon (roomy padding). |
| `logo-badge-tight.svg` / `favicon.svg` | Tighter crop for small sizes (favicons). |
| `logo-mono.svg` | Single-color version; set CSS `color` (defaults to ink) to recolor. |
| `wordmark.svg` | Horizontal lockup: badge + `vibevm` + tagline. |
| `mark-{512,256,128}.png` | Transparent mark, raster. |
| `icon-512.png`, `icon-192.png` | App / PWA icons. |
| `apple-touch-icon.png` | 180×180 for iOS. |
| `favicon-{48,32,16}.png`, `favicon.ico` | Favicons (rendered from the tight crop). |
| `showcase.png` | Overview of the system. |
| `concepts/` | The four explored directions + their contact sheet (A–D). |

SVGs are the source of truth; the PNGs/ICO are rendered from them
(headless Chrome → PIL LANCZOS downscale). To regenerate, re-run the render
steps with the SVGs as input.

## Favicon `<head>` snippet

```html
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<link rel="icon" type="image/png" sizes="32x32" href="/favicon-32.png">
<link rel="icon" type="image/png" sizes="16x16" href="/favicon-16.png">
<link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png">
```

## Clear space & minimums

- Keep clear space ≥ the width of one bracket around the mark.
- Don’t recolor the wave/walls except via `logo-mono.svg` for one-color contexts.
- Minimum legible size: 16 px (use the tight/favicon crop below 48 px).
