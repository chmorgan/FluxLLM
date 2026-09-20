#!/usr/bin/env python3
"""Preserve comparison proofs of the superseded status-mark inner edge.

Uses the dependencies and renderer from export_branding.py. Run from any directory:
    python3 scripts/preview_status_contrast.py
"""
import json

from PIL import Image, ImageDraw

from export_branding import ASSETS, PREVIEWS, asset_record, connected_components, label, render, validate_master

OUTPUT = PREVIEWS / "contrast"
# Historical menu marks used a centered 1-point stroke clipped to the original
# silhouette, leaving 0.5 points inside. Production marks are now unoutlined.
EDGE_COLORS = {"light": "#0B1F3B", "dark": "#EAF0F9"}
SCENARIOS = (
    ("Warm translucent", "#B5A6AF", "#182238", "light"),
    ("Blue translucent", "#89A8C5", "#142238", "light"),
    ("Light", "#F1F2F4", "#182238", "light"),
    ("Selected / light", "#D1D8E4", "#16223B", "light"),
    ("Dark", "#222733", "#EAF0F9", "dark"),
    ("Selected / dark", "#414B61", "#FFFFFF", "dark"),
)


def outlined_source(source, color, logical_height=18):
    """Reproduce the superseded inner edge without changing any original path."""
    clip = '''<clipPath id="contrast-edge-clip" clipPathUnits="userSpaceOnUse">
      <circle cx="13.2" cy="39.65" r="8.7"/>
      <use href="#wave-contour"/>
    </clipPath>'''
    edge = f'''<!-- Historical 0.5 pt inner edge: superseded by the unoutlined mark. -->
  <g clip-path="url(#contrast-edge-clip)" fill="none" stroke="{color}"
     stroke-width="{76 / logical_height:.8f}" stroke-linejoin="round">
    <circle cx="13.2" cy="39.65" r="8.7"/>
    <use href="#wave-contour"/>
  </g>
'''
    return source.replace("</defs>", clip + "\n  </defs>").replace("</svg>", edge + "</svg>")


def export_candidates():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    source = (ASSETS / "Masters" / "status-mark.svg").read_text()
    variants = {"original": source, "light": outlined_source(source, EDGE_COLORS["light"]),
                "dark": outlined_source(source, EDGE_COLORS["dark"])}
    exports = []
    for name, svg in variants.items():
        master = OUTPUT / f"status-{name}.svg"
        master.write_text(svg)
        validate_master(master)
        exports.append(master)
        for scale in (1, 2):
            suffix = "@2x" if scale == 2 else ""
            path = OUTPUT / f"status-{name}{suffix}.png"
            render(master, path, (24 * scale, 18 * scale), scale)
            with Image.open(path) as image:
                assert len(connected_components(image)) == 2, "Keep dot and wave separate"
                alpha = image.getchannel("A")
                assert alpha.getpixel((0, 0)) == alpha.getpixel((image.width-1, image.height-1)) == 0
                if name != "original":
                    with Image.open(OUTPUT / f"status-original{suffix}.png") as original:
                        original_alpha = original.getchannel("A")
                        assert alpha.getbbox() == original_alpha.getbbox(), "Do not enlarge silhouette"
                        assert all(old != 0 or new == 0 for old, new in zip(original_alpha.getdata(), alpha.getdata())), "No pixels outside original artwork"
            exports.append(path)
    manifest = {"status": "historical comparison; inner-edge revision superseded by the unoutlined status mark",
                "visible_inner_edge_points": 0.5,
                "edge_colors": EDGE_COLORS,
                "source": asset_record(ASSETS / "Masters" / "status-mark.svg", ASSETS),
                "files": [asset_record(path, OUTPUT) for path in exports]}
    (OUTPUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def draw_bar(canvas, xy, background, foreground, variant):
    x, y = xy
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle((x, y, x + 424, y + 42), radius=6, fill=background)
    with Image.open(OUTPUT / f"status-{variant}.png") as mark:
        canvas.alpha_composite(mark, (x + 18, y + 12))
    label(draw, (x + 53, y + 12), "≈31.7 t/s", 13, foreground)
    draw.line([(x+139,y+26),(x+146,y+22),(x+153,y+24),(x+160,y+17),
               (x+167,y+20),(x+174,y+15),(x+181,y+19),(x+188,y+18)], fill=foreground, width=1)
    label(draw, (x + 285, y + 13), "24 × 18 pt", 12, foreground)


def build_sheet():
    canvas = Image.new("RGBA", (940, 724), "#F4F6FA")
    draw = ImageDraw.Draw(canvas)
    label(draw, (28, 20), "Archived menu-mark contrast proof", 27)
    label(draw, (28, 60), "Blue/cyan fill · same silhouette · previous 0.5 pt inner edge is superseded", 16)
    label(draw, (28, 98), "CURRENT · UNOUTLINED", 14)
    label(draw, (484, 98), "PREVIOUS · NAVY / PALE EDGE", 14)
    for row, (name, background, foreground, variant) in enumerate(SCENARIOS):
        y = 129 + row * 89
        label(draw, (28, y), name, 14)
        draw_bar(canvas, (28, y + 23), background, foreground, "original")
        label(draw, (484, y), name + (" · navy edge" if variant == "light" else " · pale edge"), 14)
        draw_bar(canvas, (484, y + 23), background, foreground, variant)
    label(draw, (28, 684), "Simulated backgrounds · 1× pixels shown · HTML includes 2× at the same logical size", 14)
    canvas.convert("RGB").save(OUTPUT / "native-comparison.png")


def build_html():
    rows = []
    for scale in (1, 2):
        suffix = "@2x" if scale == 2 else ""
        rows.append(f'<h2>{scale}× representations at 24 × 18 CSS pixels</h2><div class="grid">')
        rows.append('<strong>Current unoutlined mark</strong><strong>Previous inner edge (superseded)</strong>')
        for name, background, foreground, variant in SCENARIOS:
            for key in ("original", variant):
                rows.append(f'<div><p class="caption">{name}</p><div class="bar" style="background:{background};color:{foreground}"><img class="native" src="status-{key}{suffix}.png" alt="FluxLLM {key} variant"><span>≈31.7 t/s</span><svg width="52" height="16" viewBox="0 0 52 16" aria-hidden="true"><path d="M0 13L7 9L14 11L21 4L28 7L35 2L42 6L52 5" fill="none" stroke="currentColor"/></svg></div></div>')
        rows.append('</div>')
    details = ''.join(f'<figure style="background:{background};color:{foreground}"><img class="detail" src="status-{variant}.svg" alt="Enlarged {variant} variant"><figcaption>{name} · 6× vector detail</figcaption></figure>'
                      for name, background, foreground, variant in (SCENARIOS[0], SCENARIOS[4]))
    html = '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>FluxLLM — archived contrast proof</title><style>
*{box-sizing:border-box}body{margin:0;background:#f4f6fa;color:#182238;font:16px -apple-system,BlinkMacSystemFont,Arial,sans-serif}main{max-width:1040px;padding:28px;margin:auto}p{line-height:1.5}h1{font-size:28px}h2{font-size:20px;margin-top:36px}.grid{display:grid;grid-template-columns:1fr 1fr;gap:16px 24px}.caption{font-size:13px;margin:8px 0}.bar{height:40px;border-radius:6px;display:flex;align-items:center;gap:10px;padding:0 18px;font:13px ui-monospace,Menlo,monospace}.native{width:24px;height:18px;flex:0 0 24px}.detail{width:144px;height:108px}figure{margin:0;padding:24px;border-radius:8px}figcaption{margin-top:10px;font-size:13px}a{color:#125bd8}.note{border-left:3px solid #3b82f6;padding-left:14px}
@media(max-width:540px){main{padding:12px}.grid{gap:10px}.bar{padding:0 8px;gap:6px}.bar svg{display:none}}
</style><main><h1>FluxLLM — archived contrast proof</h1>
<p class="note">Historical comparison: the previous 0.5-point inner navy edge on light surfaces and pale edge on dark surfaces have been superseded. The current status mark is unoutlined, matching the header logo. The blue/cyan gradients, original silhouette, transparent canvas, tall crest, and separate dot are retained.</p>
<p>Open at 100% browser zoom. These are simulated backgrounds, not on-device tests. The outlined variants remain here only as historical visual examples.</p>
__ROWS__<h2>Enlarged contour check</h2><div class="grid">__DETAILS__</div>
<p>Canonical production assets and runtime resources use the unoutlined mark shown in the left column. This archived proof does not confirm an app build or on-device validation. <a href="../approval.html">Current artwork page and app icon</a>.</p></main></html>
'''
    (OUTPUT / "approval.html").write_text(html.replace("__ROWS__", ''.join(rows)).replace("__DETAILS__", details))


if __name__ == "__main__":
    export_candidates()
    build_sheet()
    build_html()
    print(f"Historical contrast exports validated; archived preview: {OUTPUT / 'approval.html'}")
