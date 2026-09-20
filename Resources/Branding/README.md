# FluxLLM waveform artwork

The FluxLLM rebrand uses the existing approved detached dot and tall blue/cyan
waveform on every surface. The llama has been removed from production artwork.
Original reference images are retained only as historical provenance.

## Sources and exports

`Masters/status-mark.svg` is the single editable mark source. Its contour, dot,
and three gradients are reused exactly. `scripts/export_branding.py` generates:

- `Masters/status-mark-light.svg` and `status-mark-dark.svg`: transparent 24 × 18 pt
  menu marks with the original blue/cyan gradients and no outline in either
  appearance.
- `Masters/brand-mark-light.svg` and `brand-mark-dark.svg`: transparent 48 × 36 pt
  header marks with the original blue/cyan gradients and no outline in either
  appearance.
- `Masters/app-icon.svg`: the same unoutlined mark under one uniform scale on a
  navy app-icon tile. No llama, wordmark, external image, or shadow is present.
- `StatusBar/FluxLLMStatus*.png`: original plus light/dark 1× and 2× status exports.
- `BrandMark/FluxLLMBrand{Light,Dark}{,@2x}.png`: transparent header representations.
- `AppIcon/FluxLLM-1024.png`, `FluxLLM.iconset/`, and `FluxLLM.icns`: all ten macOS
  icon representations rendered directly from the vector master.
- `export-manifest.json`: source/export hashes, point sizes, rendering metadata, and the
  app mark's uniform transform.

The [runtime folder](../../Sources/FluxLLM/Resources/Branding) contains exactly nine
files: four menu PNGs, four header PNGs, and `FluxLLM.icns`. Light/dark variants
share the same unoutlined original colors; their filenames remain distinct for
runtime compatibility. Reference images, masters, proofs, and the extra original
menu exports are not shipped.

## Reproduction and validation

Requires Python 3, Pillow, `rsvg-convert` (librsvg), and macOS `iconutil`:

```sh
python3 scripts/export_branding.py
python3 scripts/export_branding.py --check
```

The check regenerates exports in a temporary directory and compares bytes,
including generated SVG masters and the exact runtime inventory. It verifies:

- The original waveform path, detached-dot geometry, and gradient definitions
  remain identical in every derived master.
- Marks have transparent corners and exactly two opaque components at both scales.
- Menu and header marks retain the original unoutlined fill in both appearances.
- Every one of the ten ICNS representations round-trips through Apple's decoder
  with exact RGBA equality to its source render.

The ICNS writer uses legacy RGB/alpha encoding for the two small 1× slots and
original PNG representations for the other eight slots. This preserves complete
coverage because the native encoder previously rejected a valid iconset here.

## Proofs and integration

[Artwork page](../../design/fluxllm/previews/approval.html),
[enlarged comparison](../../design/fluxllm/previews/comparison.png), and
[native-size sheet](../../design/fluxllm/previews/native-size.png) show the new icon,
transparent headers, and unoutlined menu mark on representative surfaces.
[Historical contrast proofs](../../design/fluxllm/previews/contrast/approval.html)
retain the superseded outlined menu-mark comparison. They can be reproduced with
`python3 scripts/preview_status_contrast.py`; use the main artwork page above for
current production examples.

Use original-color rendering with explicit logical dimensions. Runtime provides
`BrandingAssets.statusMark(for:)` at 24 × 18 pt, `brandMark(for:)` at 48 × 36 pt,
and `appIcon` for macOS/About. Header views use `brandMark`, not the tiled ICNS.
Menu and header marks use the same original colors without a contrast edge in
either appearance. Retain the light/dark resource names and appearance lookup for
compatibility.
Do not mutate the cached NSImage sizes.

Artwork proofs are simulations; they do not establish on-device alignment,
appearance selection, menu behavior, metrics, Settings, or Quit. Validate those
in the built app after integration.
