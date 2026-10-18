# Compact subscription tree — 2026-10-18

Source visual truth: `design/references/subscription-tree-selected.png`
(1122×1402). User override: reduce the child gutter. Keep the existing product
typography, flags, theme and three layouts; replace nesting only.

Rendered implementation: `design/screenshots/subscription-tree-large-dark-final.png`
(779×846), IAB at its default viewport, dark, large, connected, synthetic data.
Logical app canvas 1040×680 is scaled to fit. The source is a standalone list;
the implementation is a desktop app with a list panel and additional ping action.
Different demo counts/cities are intentional. No claim of whole-screen identity.

Combined full/list comparison: `design/screenshots/subscription-tree-comparison.png`.
Both artifacts were opened, then placed together in that comparison before review.
The source was normalized to width550; the rendered list crop (369,228)-(744,620)
was enlarged to550×575. This is a structural comparison, not a pixel-diff score.
Focused tree/header/row details are readable in the same board.

Additional captures: `subscription-tree-medium-light.png`,
`subscription-tree-minimal-picker.png`, `connection-failed-light.png` under
`design/screenshots/`. They cover theme, modal and failed connection states.

## Findings and required surfaces

- Typography: existing local Inter hierarchy retained, readable two-line rows.
  The standalone illustration's enlarged type is not copied into the denser app.
- Spacing/layout: child gutter24, one straight rail15, short branches to21;
  last branch stops at the last row centre. No dots, curves or duplicate rails.
  Natural heights, narrow320 and text scale1.5 tested; RTL mirrors the gutter.
- Colors/tokens: dark selected row uses translucent amber, light uses pale blue;
  latency retains green/yellow/red semantics. Guides deliberately subdued.
- Assets: existing local country flags and approved squirrel reused. No emoji
  replacement, external font fetching or reconstructed logo artwork.
- Copy/content: group title/count kept, optional name, error belongs to group.
  Extra retry strip removed without deleting the saved server list.

No actionable P0/P1/P2 difference in the requested nesting change. Browser
interactions exercised: expand backup group, select Frankfurt, switch minimal,
open configuration picker. Browser error/warning log check returned no entries.
The native Android/Windows acceptance matrix is separate from this web review.

## Comparison history

1. Widget checks found loose row widths in the new stack; changed to passthrough
   constraints. The corrected tree passed dynamic-height/RTL checks before capture.
2. Opened the source and actual browser capture together. Compact gutters and
   current product density are intentional; no visual P0/P1/P2 fix was required.

## Implementation checklist

- [x] Selected tree and explicit compact-gutter override implemented.
- [x] Source and running app opened and compared together.
- [x] Themes, collapse, selection and minimal picker checked in browser.
- [ ] Physical Android and native Windows visual acceptance (separate gate).

final result: passed
