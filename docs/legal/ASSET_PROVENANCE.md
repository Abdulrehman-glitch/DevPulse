# Asset provenance

## DevPulse pulse-aperture mark

The application icons are generated from `assets/branding/devpulse-mark.svg` by `scripts/generate-brand-assets.mjs` and the locked Tauri CLI. The original mark uses a signal-teal octagonal silhouette, two transparent opposing signal channels, and one small pulse-lime handoff point. It contains no font or third-party imagery and is distributed under Apache-2.0 as project material.

This is the project-owned DevPulse identity for the `v0.3.0` keeper build. It does not imitate or incorporate another project's branding. The transparent PNG assets and multi-frame Windows ICO are committed beside the Tauri application and are reproducible from the SVG source.

`scripts/test-brand-assets.mjs` verifies the source colour/aperture contract, real transparent and opaque RGBA pixels, expected raster dimensions, and ICO entries at 16, 24, 32, 48, 64, and 256 pixels. Redistribution and modification are permitted under Apache-2.0.

## Excluded media

The pre-public overview image was excluded because its embedded provenance did not support the historical description of the image. No product screenshot is included in this curated history. The original icon family was also excluded because its ownership and redistribution evidence was incomplete.

No retained font, animation, sound, executable, or bundled runtime binary is committed. Generated application icon assets are the sole retained generated media; runtime and installer artifacts are produced only in ignored or release-output paths.
