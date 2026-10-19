# Import autofill and QR actions — 2026-10-19

Target: latest user refinement of the approved compact import, retaining existing
Inter and palette. Before: `design/screenshots/compact-import/minimal-add-light-detail.png`.
After: `design/screenshots/import-autofill/clipboard-name-light-detail.png`.
Both400×440 crops were opened together for visual comparison. Originals retain
the entire IAB viewport779×846 and are not edited; detail copies crop the app only.

- Typography/assets: unchanged local Inter and Cupertino library; name prefix tag
  matches the link prefix size18. Existing themes, fonts and logo reused.
- Layout: persistent name above all tabs,48px field and16px gap; QR has only two
 64px icon targets. No overflow in observed minimal/light or Text mode.
- Colors: existing light blue tokens; no new palette or native window changes.
- Copy: no collapsed name caption; file/clipboard choices appear only on demand.
- Behavior: synthetic HTTPS clipboard auto-populates, synthetic provider metadata
  fills ExVPN Demo, name remains when switching Link/Text/QR. Clipboard original
  restored after QA. Three focused tests cover auto-origin on import, unrelated
  clipboard, stale metadata/manual override and selection-only notifications.

Targeted analyzer PASS; browser error log empty. Source96444e3. No P0/P1/P2
findings remain for this scoped design. Physical camera scanning, image clipboard
runtime, native camera and Android/Windows delivery were not accepted here.
No full suite, native build, installer, CI or release was run.

final result: passed (scoped web design and autofill only)

---

# Compact import and minimal windows — 2026-10-19

Source: user attachment `codex-clipboard-4bd7389e-5ba3-4cae-b53b-146b40596f36.png`,
425×450, saved as `design/references/import-before-20261019.png`.
The request is a scoped redesign, not a pixel clone. Preserve approved Inter,
theme tokens, flags and controls. Existing visual language is the target.

IAB implementation captures: `design/screenshots/compact-import/`, viewport779×846.
Logical minimal400×440 is shown at1:1; medium440×760 is scaled to fit the viewport.
The source card is320×392; the medium implementation card is about372×260 in
the full browser capture. Source and implementation were opened together for
comparison; unrelated browser/desktop margins are excluded from the judgement.
The minimal detail image is an explicitly cropped copy of the unedited capture.

Findings fixed: original nested dimmed frames waste the small window; minimal
now fills the complete app canvas. Initial icon-font cache on127.0.0.1 omitted
new glyphs; a fresh localhost origin displays the full fonts. Final captures
use that origin for the new form. No brand asset was replaced or approximated.

- Typography: existing Inter, title20, normal control hierarchy, no clipped labels.
- Spacing/layout:20px form gutter,38px tabs,42px primary action; optional name
  collapsed initially. Medium shrinks to content, minimal pins the action below
  scrollable content. Settings and server picker fill minimal without nesting.
- Color: existing white/blue tokens; existing dark tokens remain in source,
  dark runtime was not retested in this narrowly scoped pass.
- Assets: existing Cupertino icons and local fonts; QR is an actual library icon,
  with no raster placeholder or generated artwork.
- Copy: removed persistence/developer footnote and duplicate Cancel; close X
  remains. Unsupported-only warning icon absent, refresh-error simulation shows
  red exclamation beside the relevant count. Supported server rows remain visible.
- Interaction: Link/Text/QR and optional-name disclosure observed, QR action and
  disabled submit shown correctly. Close and refresh simulation work; no real
  subscription was sent, and no native bridge or network settings were changed.

Browser error log empty. No P0/P1/P2 findings remain in these observed states.
No native build, automated test suite, physical Android QA or production install
was performed. Parser/pending-update semantics remain a separate implementation
task. Source commit12aa7aa; no release/tag or push that starts CI.

final result: passed (scoped web design only)

---

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
