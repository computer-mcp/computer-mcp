# Computer MCP brand

Computer MCP is the master identity for the App, website, organization and
first-party plugins. [ProductIdentity](../../Documentation/Architecture/ProductIdentity.md)
owns product meaning and boundaries; [brand.json](brand.json) owns the exact
name, bilingual promise, family names, palette and asset dimensions.

## Voice

**Let ChatGPT use your local tools.**

**让 ChatGPT，用上你的本机工具。**

Lead with the user's task and direct access to local capabilities. Explain
permissions and prerequisites where they affect a decision. Direct, Local,
Composable, Multi-computer and Governed are the five pillars. Treat Codex as an
optional integration. Use the dated, sourced
[comparison](../../Documentation/Reference/ProductComparison.md) when explaining
Dots or Codex Remote. Describe fit; do not promise universal superiority or
unmetered usage.

## Visual system

Use a quiet macOS-native composition: graphite, silver and white, system
typography, generous space and precise alignment. Functional system colors
communicate actions and state. Materials are restrained, with a subtle neutral
highlight on the App tile. Body content stays live text. Technical examples may
use a system monospaced companion.

The symbol is a rounded computer display with a centered circular control. Its
single silhouette remains readable at small sizes. The editable master is
[Sources/symbol.svg](Sources/symbol.svg); the App tile and presentation templates
compose that same geometry. Keep its proportions and clear space. The control
is part of the mark, not a live status indicator.

- Use `mark.svg` or `mark.png` for navigation and organization identity.
- Use `symbol.svg` on an existing quiet surface; its silver silhouette needs a
  dark background. Use the graphite `symbol-dark.svg` on light backgrounds.
- Use `AppIcon.icns` in the macOS bundle. The icon has transparent margins and
  a rounded tile; do not crop or add another frame.
- Use the generated social card for repository previews and sharing. Keep the
  master name dominant and the integration name secondary on family cards.
- Keep at least one symbol stroke's width of clear space around the mark.
  At 16–32 px, use the supplied exports and verify their contrast and silhouette.
- Product marks do not replace semantic state icons, navigation labels or
  accessibility text in the App.

The core mark contains no vendor logo. Vendor marks may identify a specific
integration, unmodified, secondary and with the vendor's attribution and usage
terms. Obtain them from the vendor's official distribution and record source
and checksum. Use the vendor's name as text when an official asset or permitted
use cannot be established. Do not invent substitute vendor glyphs or imply a
partnership. The SDK fork retains its upstream identity.

## Delivery and ownership

`Sources/` contains editable artwork. `Scripts/brand.py generate` composes the
master symbol into App, social and family assets. `Exports/` contains the delivery set;
`manifest.json` binds source and output digests. `python3 Scripts/brand.py check`
checks the committed delivery, product copy and App packaging inputs without a
graphics dependency. Regeneration uses the pinned maintainer renderer in
`Tools/Brand/`; it is not a product runtime dependency. Run `npm ci` in that
directory, then run `python3 Scripts/brand.py generate` from the repository root.
The manifest records renderer versions. Verify repeated generation produces
identical output digests before accepting a renderer or artwork change.

The website imports a locked copy of the delivery and stable facts. Its
`DESIGN.md` owns website-specific composition, spacing and responsive behavior.
The main contract remains the source for identity changes. Family README headers
link to the master brand and retain integration-specific technical manuals.

App icon or other bundled resource changes alter candidate bytes. Follow
[Versioning and Release](../../Documentation/Architecture/VersioningAndRelease.md)
for the compatible patch candidate and exact installed acceptance.
