# Computer MCP brand assets

[BRAND.md](BRAND.md) owns the verbal and visual system.
[brand.json](brand.json) contains stable machine-readable facts.
[Product Identity](../../Documentation/Architecture/ProductIdentity.md) owns
product meaning and boundaries.

- [Sources](Sources/): editable symbol and composition templates.
- [Exports](Exports/): generated delivery, including the master mark,
  bilingual social cards, six plugin cards, App icon and size-specific PNGs.
- [Export manifest](Exports/manifest.json): source, renderer and output digests.
- [App icon](Exports/AppIcon.icns): the icon copied into the macOS App bundle.

Regenerate with the pinned maintainer renderer:

```sh
npm ci --prefix Tools/Brand
python3 Scripts/brand.py generate
python3 Scripts/brand.py check
```

Import an exact delivery into a website, first-party plugin or organization
profile checkout, then verify it:

```sh
python3 Scripts/brand.py sync ../computer-mcp.github.io
python3 Scripts/brand.py check --consumer ../computer-mcp.github.io
```

Each consumer receives a lock and a standalone check script for its own CI.
The website's `DESIGN.md` owns composition and responsive application. Identity
changes originate here and require regeneration and consumer synchronization.
App-bundled changes follow the existing
[release contract](../../Documentation/Architecture/VersioningAndRelease.md).
