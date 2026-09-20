#!/usr/bin/env python3
"""Export FluxLLM waveform artwork and its runtime resource copies.

Requires Python 3, Pillow, librsvg's rsvg-convert, and macOS iconutil.
Does not compile the app or change its resource wiring.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import xml.etree.ElementTree as ET

from PIL import Image, ImageDraw, ImageFont, PngImagePlugin

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "Resources" / "Branding"
RUNTIME_ASSETS = ROOT / "Sources" / "FluxLLM" / "Resources" / "Branding"
PREVIEWS = ROOT / "design" / "fluxllm" / "previews"
REFERENCES = ROOT / "design" / "fluxllm" / "reference"
SVG_NS = "{http://www.w3.org/2000/svg}"
ICON_SIZES = ((16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2))
# Keep the existing appearance-specific resource names; both use the same
# unoutlined blue/cyan artwork as the header.
APPEARANCES = ("light", "dark")
RUNTIME_SOURCES = {
    **{f"FluxLLMStatus{appearance}{suffix}.png": f"StatusBar/FluxLLMStatus{appearance}{suffix}.png"
       for appearance in ("Light", "Dark") for suffix in ("", "@2x")},
    **{f"FluxLLMBrand{appearance}{suffix}.png": f"BrandMark/FluxLLMBrand{appearance}{suffix}.png"
       for appearance in ("Light", "Dark") for suffix in ("", "@2x")},
    "FluxLLM.icns": "AppIcon/FluxLLM.icns",
}


def app_icon_source(source):
    """Reuse the exact approved mark, with one uniform scale on the navy tile."""
    definitions = source.split("<defs>", 1)[1].split("</defs>", 1)[0]
    artwork = source.split("</defs>", 1)[1].split("</svg>", 1)[0]
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-labelledby="title description">
  <title id="title">FluxLLM app icon</title>
  <desc id="description">The approved detached dot and tall blue/cyan waveform, uniformly enlarged on a navy app-icon tile. Generated from status-mark.svg without redrawing its contour.</desc>
  <defs>
    <linearGradient id="tile" x1="400" y1="48" x2="572" y2="976" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#0B315B"/>
      <stop offset="0.46" stop-color="#081D3D"/>
      <stop offset="1" stop-color="#030B24"/>
    </linearGradient>
    <radialGradient id="tileLight" cx="650" cy="166" r="760" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#1261A4" stop-opacity="0.18"/>
      <stop offset="0.65" stop-color="#061631" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="tileEdge" x1="512" y1="48" x2="512" y2="976" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#378BDF" stop-opacity="0.65"/>
      <stop offset="0.14" stop-color="#1C538A" stop-opacity="0.10"/>
      <stop offset="0.8" stop-color="#112A50" stop-opacity="0.05"/>
      <stop offset="1" stop-color="#607399" stop-opacity="0.22"/>
    </linearGradient>{definitions}
  </defs>
  <rect id="navy-tile" x="48" y="48" width="928" height="928" rx="204" fill="url(#tile)"/>
  <rect x="48" y="48" width="928" height="928" rx="204" fill="url(#tileLight)"/>
  <rect x="49" y="49" width="926" height="926" rx="203" fill="none" stroke="url(#tileEdge)" stroke-width="2"/>
  <g id="brand-mark" transform="translate(108 208) scale(8)">{artwork}  </g>
</svg>
'''


def validate_shared_mark(source, derived):
    """Reject accidental redraws, gradient substitutions or joined dots."""
    original = ET.fromstring(source)
    result = ET.fromstring(derived)
    for identifier in ("wave-contour", "separate-dot", "wave-blue", "wave-cyan", "dot-blue"):
        before = next(node for node in original.iter() if node.get("id") == identifier)
        after = next(node for node in result.iter() if node.get("id") == identifier)
        assert ET.tostring(before).strip() == ET.tostring(after).strip(), identifier


def require_tool(name):
    executable = shutil.which(name)
    if executable is None:
        raise SystemExit(f"Missing {name}; install the export dependency and run again.")
    return executable


def validate_master(path):
    root = ET.parse(path).getroot()
    if not list(root.iter(SVG_NS + "path")):
        raise ValueError(f"{path}: expected editable vector paths")
    for element in root.iter():
        if element.tag in (SVG_NS + "image", SVG_NS + "filter"):
            raise ValueError(f"{path}: raster embedding and baked shadow filters are not allowed")
        for key, value in element.attrib.items():
            if key.endswith("href") and not value.startswith("#"):
                raise ValueError(f"{path}: external resource reference")
    return root


def render(source, destination, size, scale=1):
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([require_tool("rsvg-convert"), "--width", str(size[0]), "--height", str(size[1]),
                    "--output", str(destination), str(source)], check=True)
    with Image.open(destination) as image:
        image = image.convert("RGBA")
        if image.size != size:
            raise ValueError(f"Unexpected export size: {destination}: {image.size}")
        metadata = PngImagePlugin.PngInfo()
        metadata.add(b"sRGB", b"\x00")
        image.save(destination, pnginfo=metadata, dpi=(72 * scale, 72 * scale), compress_level=9)


def connected_components(image):
    mask = image.getchannel("A").point(lambda value: 255 if value >= 128 else 0)
    foreground = {(x, y) for y in range(image.height) for x in range(image.width) if mask.getpixel((x, y))}
    result = []
    while foreground:
        seed = foreground.pop()
        component = [seed]
        stack = [seed]
        while stack:
            x, y = stack.pop()
            for neighbour in ((x-1,y),(x+1,y),(x,y-1),(x,y+1)):
                if neighbour in foreground:
                    foreground.remove(neighbour)
                    component.append(neighbour)
                    stack.append(neighbour)
        result.append(component)
    return result


def asset_record(path, base):
    record = {"file": str(path.relative_to(base)), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    if path.suffix == ".png":
        with Image.open(path) as image:
            record.update(pixels=list(image.size), mode=image.mode)
    return record


def write_icns(iconset, output):
    """Package all ten rendered sizes without resampling any representation."""
    chunks = []
    # Use legacy RGB RLE and alpha for the two small 1x representations.
    # Apple tooling misdecoded PNG icp4/icp5 slots during export validation.
    for rgb_tag, alpha_tag, name in (
        (b"is32", b"s8mk", "icon_16x16.png"),
        (b"il32", b"l8mk", "icon_32x32.png"),
    ):
        with Image.open(iconset / name) as source:
            image = source.convert("RGBA")
            rgb = bytearray()
            for channel in ("R", "G", "B"):
                values = image.getchannel(channel).tobytes()
                for start in range(0, len(values), 128):
                    block = values[start:start + 128]
                    rgb.append(len(block) - 1)
                    rgb.extend(block)
            chunks.extend(((rgb_tag, bytes(rgb)), (alpha_tag, image.getchannel("A").tobytes())))
    for tag, name in (
        (b"ic11", "icon_16x16@2x.png"), (b"ic12", "icon_32x32@2x.png"),
        (b"ic07", "icon_128x128.png"), (b"ic13", "icon_128x128@2x.png"),
        (b"ic08", "icon_256x256.png"), (b"ic14", "icon_256x256@2x.png"),
        (b"ic09", "icon_512x512.png"), (b"ic10", "icon_512x512@2x.png"),
    ):
        chunks.append((tag, (iconset / name).read_bytes()))
    toc = b"".join(tag + struct.pack(">I", len(data) + 8) for tag, data in chunks)
    body = b"TOC " + struct.pack(">I", len(toc) + 8) + toc
    body += b"".join(tag + struct.pack(">I", len(data) + 8) + data for tag, data in chunks)
    output.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)


def validate_icns(icns, iconset):
    """Verify Apple's decoder reproduces every source RGBA pixel at every size."""
    with tempfile.TemporaryDirectory(prefix="fluxllm-icns-check-") as temporary:
        extracted = Path(temporary) / "decoded.iconset"
        subprocess.run([require_tool("iconutil"), "--convert", "iconset", "--output",
                        str(extracted), str(icns)], check=True)
        expected = {path.name for path in iconset.glob("*.png")}
        actual = {path.name for path in extracted.glob("*.png")}
        if actual != expected:
            raise ValueError(f"ICNS representations differ: {actual ^ expected}")
        for name in sorted(expected):
            with Image.open(iconset / name) as source, Image.open(extracted / name) as decoded:
                if source.size != decoded.size or source.convert("RGBA").tobytes() != decoded.convert("RGBA").tobytes():
                    raise ValueError(f"ICNS round-trip changed pixels: {name}")


def validate_status(path, original=None):
    with Image.open(path) as image:
        assert image.mode == "RGBA"
        alpha = image.getchannel("A")
        assert alpha.getpixel((0, 0)) == 0
        assert alpha.getpixel((image.width-1, image.height-1)) == 0
        assert len(connected_components(image)) == 2, "Dot must remain separate from wave"
        assert alpha.getextrema()[1] == 255
        if original is not None:
            with Image.open(original) as original_image:
                assert image.size == original_image.size
                assert image.tobytes() == original_image.convert("RGBA").tobytes(), "Status variants must match the unoutlined source exactly"


def validate_runtime_inventory(directory):
    actual = {str(path.relative_to(directory)) for path in directory.rglob("*") if path.is_file()}
    expected = set(RUNTIME_SOURCES)
    if actual != expected:
        raise ValueError(f"Runtime branding files differ: missing {expected - actual}; unexpected {actual - expected}")


def copy_runtime_assets(destination, runtime_destination):
    runtime_destination.mkdir(parents=True, exist_ok=True)
    paths = []
    for name, relative_source in RUNTIME_SOURCES.items():
        path = runtime_destination / name
        shutil.copyfile(destination / relative_source, path)
        paths.append(path)
    validate_runtime_inventory(runtime_destination)
    return paths


def export_assets(destination, runtime_destination):
    masters = ASSETS / "Masters"
    status = masters / "status-mark.svg"
    validate_master(status)
    source = status.read_text()
    app = destination / "Masters" / "app-icon.svg"
    app.parent.mkdir(parents=True, exist_ok=True)
    app.write_text(app_icon_source(source))
    validate_shared_mark(source, app.read_text())
    validate_master(app)
    derived_masters = [app]
    status_paths = []
    variants = {"": status}
    for appearance in APPEARANCES:
        master = destination / "Masters" / f"status-mark-{appearance}.svg"
        master.parent.mkdir(parents=True, exist_ok=True)
        master.write_text(source)
        validate_master(master)
        validate_shared_mark(source, master.read_text())
        derived_masters.append(master)
        variants[appearance.title()] = master
    for appearance, master in variants.items():
        for scale in (1, 2):
            suffix = "@2x" if scale == 2 else ""
            path = destination / "StatusBar" / f"FluxLLMStatus{appearance}{suffix}.png"
            render(master, path, (24 * scale, 18 * scale), scale)
            original = destination / "StatusBar" / f"FluxLLMStatus{suffix}.png" if appearance else None
            validate_status(path, original)
            status_paths.append(path)
    brand_paths = []
    # Both header appearances use the approved unoutlined blue/cyan artwork.
    # Keep their existing resource names so the app's asset loading is unchanged.
    header_source = source.replace('width="24" height="18"', 'width="48" height="36"')
    for appearance in APPEARANCES:
        master = destination / "Masters" / f"brand-mark-{appearance}.svg"
        master.write_text(header_source)
        validate_master(master)
        validate_shared_mark(source, master.read_text())
        derived_masters.append(master)
        for scale in (1, 2):
            suffix = "@2x" if scale == 2 else ""
            path = destination / "BrandMark" / f"FluxLLMBrand{appearance.title()}{suffix}.png"
            render(master, path, (48 * scale, 36 * scale), scale)
            validate_status(path)
            brand_paths.append(path)
    app_dir = destination / "AppIcon"
    iconset = app_dir / "FluxLLM.iconset"
    icon_paths = []
    for points, scale in ICON_SIZES:
        suffix = "@2x" if scale == 2 else ""
        path = iconset / f"icon_{points}x{points}{suffix}.png"
        render(app, path, (points * scale, points * scale), scale)
        icon_paths.append(path)
    large_app = app_dir / "FluxLLM-1024.png"
    render(app, large_app, (1024, 1024))
    icns = app_dir / "FluxLLM.icns"
    write_icns(iconset, icns)
    validate_icns(icns, iconset)
    paths = derived_masters + sorted(status_paths + brand_paths + icon_paths + [large_app]) + [icns]
    runtime_paths = copy_runtime_assets(destination, runtime_destination)
    manifest = {
        "concept": "FluxLLM tall waveform", "approval": "unoutlined status and header marks approved; original dimensions and blue/cyan gradients preserved",
        "status_logical_points": [24, 18], "rendering": "original color; transparent status background",
        "brand_logical_points": [48, 36], "app_mark_transform": "translate(108 208) scale(8)",
        "status_visible_inner_edge_points": 0, "status_edge_colors": {},
        "brand_visible_inner_edge_points": 0,
        "sources": [asset_record(status, ASSETS)],
        "exports": [asset_record(path, destination) for path in paths],
        "runtime_exports": [{**asset_record(path, runtime_destination), "source": RUNTIME_SOURCES[path.name]}
                            for path in runtime_paths],
    }
    (destination / "export-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return paths, runtime_paths


def font(size):
    for path in ("/System/Library/Fonts/Supplemental/Arial.ttf", "/Library/Fonts/Arial.ttf"):
        if Path(path).is_file():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default(size=size)


def label(draw, xy, text, size=16, fill="#27364C"):
    draw.text(xy, text, font=font(size), fill=fill)


def paste_center(canvas, image, box):
    x0, y0, x1, y1 = box
    image = image.convert("RGBA")
    canvas.alpha_composite(image, (int((x0+x1-image.width)/2), int((y0+y1-image.height)/2)))


def build_previews():
    PREVIEWS.mkdir(parents=True, exist_ok=True)
    status_master = ASSETS / "Masters" / "status-mark-light.svg"
    app_master = ASSETS / "Masters" / "app-icon.svg"
    with tempfile.TemporaryDirectory(prefix="fluxllm-proof-") as temporary:
        temp = Path(temporary)
        render(status_master, temp / "status.png", (404, 304))
        render(app_master, temp / "app.png", (304, 304))
        board = Image.new("RGBA", (1040, 800), "#F4F6FA")
        draw = ImageDraw.Draw(board)
        label(draw, (36, 22), "FluxLLM · one tall waveform, every surface", 27)
        label(draw, (36, 61), "Existing approved contour · uniformly enlarged · no llama artwork", 16)
        label(draw, (36, 98), "ORIGINAL WAVE REFERENCE · 4×", 14)
        label(draw, (546, 98), "FLUXLLM APP ICON", 14)
        with Image.open(REFERENCES / "status-wave-reference.png") as ref:
            ref = ref.resize((404, 304), Image.Resampling.NEAREST)
            paste_center(board, ref, (36, 120, 494, 424))
        with Image.open(temp / "app.png") as image:
            paste_center(board, image, (546, 120, 1004, 424))
        label(draw, (36, 448), "LARGE HEADER MARK · DARK SURFACE", 14)
        label(draw, (546, 448), "MENU MARK · NO OUTLINE · 4×", 14)
        draw.rounded_rectangle((36, 474, 494, 778), radius=14, fill="#0B1F3B")
        render(ASSETS / "Masters" / "brand-mark-dark.svg", temp / "brand.png", (404, 304))
        with Image.open(temp / "brand.png") as image:
            paste_center(board, image, (36,474,494,778))
        with Image.open(temp / "status.png") as image:
            paste_center(board, image, (546,474,1004,778))
        board.convert("RGB").save(PREVIEWS / "comparison.png")

    proof = Image.new("RGBA", (880, 754), "#F4F6FA")
    draw = ImageDraw.Draw(proof)
    label(draw, (28, 20), "Native-size artwork previews", 27)
    label(draw, (28, 58), "Menu mark 24 × 18 pt · header mark 48 × 36 pt · simulated surfaces", 15)
    scenarios = (("Light", "#F1F2F4", "#182238"), ("Dark", "#222733", "#EAF0F9"),
                 ("Selected / light", "#D1D8E4", "#16223B"), ("Selected / dark", "#414B61", "#FFFFFF"),
                 ("Warm translucent sample", "#B5A6AF", "#182238"), ("Blue translucent sample", "#89A8C5", "#142238"))
    for index, (name, background, foreground) in enumerate(scenarios):
        appearance = "Dark" if "dark" in name.lower() else "Light"
        with Image.open(ASSETS / "StatusBar" / f"FluxLLMStatus{appearance}.png") as mark:
            mark = mark.convert("RGBA")
            x = 28 + (index % 2) * 424
            y = 104 + (index // 2) * 93
            label(draw, (x, y), name, 14)
            draw.rounded_rectangle((x, y+24, x+396, y+65), radius=6, fill=background)
            proof.alpha_composite(mark, (x+18, y+36))
            label(draw, (x+50, y+36), "≈31.7 t/s", 13, foreground)
            coords = [(x+134,y+49),(x+141,y+45),(x+148,y+47),(x+155,y+40),
                      (x+162,y+43),(x+169,y+38),(x+176,y+42),(x+183,y+41)]
            draw.line(coords, fill=foreground, width=1)
            label(draw, (x+218,y+36), "24 × 18", 12, foreground)
    label(draw, (28, 397), "Transparent header mark · native size", 20)
    for index, (appearance, background, foreground) in enumerate(
        (("Light", "#FFFFFF", "#182238"), ("Dark", "#15243D", "#EAF0F9"))
    ):
        x = 28 + index * 424
        draw.rounded_rectangle((x, 432, x+396, 496), radius=10, fill=background)
        with Image.open(ASSETS / "BrandMark" / f"FluxLLMBrand{appearance}.png") as mark:
            proof.alpha_composite(mark.convert("RGBA"), (x+16, 446))
        label(draw, (x+78, 448), "FluxLLM", 23, foreground)
    label(draw, (28, 521), "App icon · native pixel sizes", 20)
    x = 30
    for size in (16, 32, 64, 128):
        with tempfile.TemporaryDirectory(prefix="fluxllm-size-") as temporary:
            image_path = Path(temporary) / "icon.png"
            render(app_master, image_path, (size,size))
            with Image.open(image_path) as image:
                proof.alpha_composite(image.convert("RGBA"), (x, 560))
        label(draw, (x, 700), str(size), 13)
        x += size + 63
    label(draw, (28, 731), "Open approval.html at 100% zoom for fixed CSS sizes and 1× / 2× image selection.", 14)
    proof.convert("RGB").save(PREVIEWS / "native-size.png")
    build_html()


def build_html():
    (PREVIEWS / "approval.html").write_text("""<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>FluxLLM — waveform artwork</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#f3f5f9;color:#15243d;font:16px -apple-system,BlinkMacSystemFont,Arial,sans-serif}main{max-width:1120px;margin:40px auto;padding:0 24px 60px}h1{font-size:30px;margin-bottom:12px}h2{font-size:21px;margin-top:34px}p{line-height:1.55}small{color:#5c687a}.grid{display:grid;grid-template-columns:1fr 1fr;gap:22px}.panel{padding:22px;background:white;border:1px solid #dbe1eb;border-radius:14px}.panel h3{font-size:14px;font-weight:600;margin:0 0 16px}.large-status{display:block;width:404px;height:304px;max-width:100%;object-fit:contain;margin:auto}.large-app{display:block;width:304px;height:304px;object-fit:contain;margin:auto}.reference{image-rendering:pixelated}.bar{height:36px;display:flex;align-items:center;gap:8px;padding:0 16px;border-radius:7px}.mark{width:24px;height:18px;flex:0 0 24px;object-fit:contain}.metric{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;min-width:74px}.bars{display:grid;grid-template-columns:1fr 1fr;gap:20px}.sample small{display:block;margin-bottom:8px}.light{background:#f1f2f4;color:#182238}.dark{background:#222733;color:#eaf0f9}.selected-light{background:#d1d8e4;color:#16223b}.selected-dark{background:#414b61;color:white}.warm{background:linear-gradient(100deg,#b5a6af,#bba9a0);color:#182238}.blue{background:linear-gradient(100deg,#89a8c5,#a5b0c2);color:#142238}.sizes{display:flex;gap:44px;align-items:flex-start;flex-wrap:wrap}.size figure{margin:0}.size figcaption{font-size:12px;margin-top:12px}.checker{background-color:#e7ebf1;background-image:linear-gradient(45deg,#fff 25%,transparent 25%),linear-gradient(-45deg,#fff 25%,transparent 25%),linear-gradient(45deg,transparent 75%,#fff 75%),linear-gradient(-45deg,transparent 75%,#fff 75%);background-size:16px 16px;background-position:0 0,0 8px,8px -8px,-8px 0px}.note{border-left:3px solid #3b82f6;padding-left:16px}a{color:#125bd8}.trace{width:52px;height:16px;fill:none;stroke:currentColor;stroke-width:1.2}
@media(max-width:700px){.grid,.bars{grid-template-columns:1fr}.large-status{height:auto}}
</style><main><h1>FluxLLM · the tall waveform</h1>
<p>The approved waveform supplies the app icon, transparent headers, and menu mark. Menu and header artwork use the same unoutlined blue/cyan gradients. All artwork is rendered directly from vector paths.</p>
<p class="note">Preserved: detached dot, tall crest, deep left trough, smaller right trough, and blue/cyan gradients. Every size reuses the same contour. Header and menu artwork have no tile or shadow; only the app icon uses the navy tile.</p>
<h2>Enlarged comparison</h2><div class="grid">
<div class="panel"><h3>Transparent header mark</h3><div class="checker"><img class="large-status" src="../../../Resources/Branding/Masters/brand-mark-light.svg" alt="FluxLLM detached dot and tall waveform"></div></div>
<div class="panel"><h3>FluxLLM app icon</h3><img class="large-app" src="../../../Resources/Branding/Masters/app-icon.svg" alt="Large blue and cyan waveform on navy app icon"></div>
<div class="panel"><h3>Reference status crop · 4×</h3><img class="large-status reference" src="../reference/status-wave-reference.png" alt="Original status waveform crop"></div>
<div class="panel"><h3>Unoutlined status mark · transparency check</h3><div class="checker"><img class="large-status" src="../../../Resources/Branding/Masters/status-mark-light.svg" alt="Approved detached dot and tall asymmetric wave without an outline"></div></div></div>
<h2>24 × 18 point menu-mark test</h2><p>Keep browser zoom at 100%. Each mark is exactly 24 × 18 CSS pixels. These are simulated surfaces, not screenshots of an integrated app. The first column uses the 1× PNG; the second uses the 2× PNG at the same logical size.</p>
<div class="bars">__BARS__</div>
<p class="note">The menu mark has no outline in light, dark, or selected appearances. Its 24 × 18 point size, blue/cyan fill, and original contours are preserved. <a href="contrast/approval.html">Historical outline comparison</a>.</p>
<h2>48 × 36 point transparent header mark</h2><p>The header uses the original blue/cyan gradients without an outline on both light and dark surfaces.</p><div class="bars">__HEADERS__</div>
<h2>App icon at native sizes</h2><div class="sizes">__SIZES__</div>
<h2>Exports prepared</h2><p><a href="../../../Resources/Branding/StatusBar/FluxLLMStatusLight.png">Light 1×</a> · <a href="../../../Resources/Branding/StatusBar/FluxLLMStatusLight@2x.png">Light 2×</a> · <a href="../../../Resources/Branding/StatusBar/FluxLLMStatusDark.png">Dark 1×</a> · <a href="../../../Resources/Branding/StatusBar/FluxLLMStatusDark@2x.png">Dark 2×</a> · <a href="../../../Resources/Branding/AppIcon/FluxLLM-1024.png">App icon 1024 px</a> · <a href="../../../Resources/Branding/AppIcon/FluxLLM.icns">macOS .icns</a></p>
<p>Wave-only branding was requested and approved for integration. These artwork proofs do not confirm an app build or on-device validation of alignment, appearance switching, menu behavior, metrics, or Quit.</p></main></html>""".replace("__BARS__", html_bars()).replace("__SIZES__", html_sizes()).replace("__HEADERS__", html_headers()))


def html_headers():
    return "".join(
        f'<div class="sample"><small>{appearance} · {scale}× representation</small><div class="bar {appearance.lower()}" style="height:68px;gap:14px"><img width="48" height="36" src="../../../Resources/Branding/BrandMark/FluxLLMBrand{appearance}{"@2x" if scale == 2 else ""}.png" alt="FluxLLM"><strong style="font-size:22px">FluxLLM</strong></div></div>'
        for appearance in ("Light", "Dark") for scale in (1, 2))


def html_bars():
    result = []
    for style in ("light", "dark", "selected-light", "selected-dark", "warm", "blue"):
        for scale in (1,2):
            suffix = "@2x" if scale == 2 else ""
            appearance = "Dark" if "dark" in style else "Light"
            result.append(f'<div class="sample"><small>{style.replace("-"," ").title()} · {scale}× representation</small><div class="bar {style}"><img class="mark" width="24" height="18" src="../../../Resources/Branding/StatusBar/FluxLLMStatus{appearance}{suffix}.png" alt="FluxLLM"><span class="metric">≈31.7 t/s</span><svg class="trace" viewBox="0 0 52 16" aria-hidden="true"><path d="M0 13L7 9L14 11L21 4L28 7L35 2L42 6L52 5"/></svg></div></div>')
    return "".join(result)


def html_sizes():
    files = {16:"icon_16x16.png",32:"icon_32x32.png",64:"icon_32x32@2x.png",128:"icon_128x128.png",256:"icon_256x256.png"}
    return "".join(f'<div class="size"><figure><img width="{size}" height="{size}" src="../../../Resources/Branding/AppIcon/FluxLLM.iconset/{name}" alt="FluxLLM app icon at {size} pixels"><figcaption>{size} × {size}</figcaption></figure></div>' for size,name in files.items())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="regenerate exports in a temporary directory and compare without modifying assets")
    args = parser.parse_args()
    if args.check:
        with tempfile.TemporaryDirectory(prefix="fluxllm-branding-check-") as temporary:
            directory = Path(temporary) / "canonical"
            runtime_directory = Path(temporary) / "runtime"
            paths, runtime_paths = export_assets(directory, runtime_directory)
            for path in paths + [directory / "export-manifest.json"]:
                existing = ASSETS / path.relative_to(directory)
                if not existing.exists() or existing.read_bytes() != path.read_bytes():
                    raise SystemExit(f"Export differs or is missing: {existing}")
            validate_runtime_inventory(RUNTIME_ASSETS)
            for path in runtime_paths:
                existing = RUNTIME_ASSETS / path.name
                if existing.read_bytes() != path.read_bytes():
                    raise SystemExit(f"Runtime export differs: {existing}")
        print("All canonical and runtime exports match the approved SVG masters; dimensions, transparency, silhouette, detached dot and ICNS checks passed.")
    else:
        paths, runtime_paths = export_assets(ASSETS, RUNTIME_ASSETS)
        build_previews()
        print(f"Exported {len(paths)} canonical files and {len(runtime_paths)} runtime files; preview: {PREVIEWS / 'approval.html'}")


if __name__ == "__main__":
    main()
