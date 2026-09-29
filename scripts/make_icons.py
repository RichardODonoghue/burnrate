#!/usr/bin/env python3
"""Generates BurnRate's icon set with Pillow.

    python3 scripts/make_icons.py

Produces the PNGs Tauri's bundler wants, a macOS .icns (via iconutil) and a
Windows .ico. The tray image is a black template (macOS recolours it; Linux
themes it), the app icon is a gauge arc on a dark rounded square.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON_DIR = os.path.join(ROOT, "src-tauri", "icons")

BG = (18, 20, 26, 255)
ARC = (255, 149, 64, 255)
ARC_DIM = (70, 78, 94, 255)
NEEDLE = (240, 246, 255, 255)


def gauge(size: int, *, needle_deg: float = 42.0) -> Image.Image:
    """A 270° gauge arc with a needle, drawn at `size`×`size`."""
    scale = 4  # supersample for smooth edges
    s = size * scale
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    pad = int(s * 0.11)
    box = (pad, pad, s - pad, s - pad)
    width = max(2, int(s * 0.105))
    draw.arc(box, start=135, end=405, fill=ARC_DIM, width=width)
    draw.arc(box, start=135, end=135 + 270 * 0.62, fill=ARC, width=width)

    cx = cy = s / 2
    radius = (s / 2 - pad) * 0.78
    import math

    angle = math.radians(135 + 270 * (needle_deg / 100.0))
    nx, ny = cx + radius * math.cos(angle), cy - radius * math.sin(angle)
    draw.line((cx, cy, nx, ny), fill=NEEDLE, width=max(2, int(s * 0.062)))
    draw.ellipse(
        (cx - width * 0.6, cy - width * 0.6, cx + width * 0.6, cy + width * 0.6),
        fill=NEEDLE,
    )
    return img.resize((size, size), Image.LANCZOS)


def app_icon(size: int) -> Image.Image:
    """Dark rounded square with a gauge, drawn supersampled then downscaled."""
    s = size * 4
    mask = Image.new("L", (s, s), 0)
    radius = int(s * 0.22)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, s - 1, s - 1), radius=radius, fill=255)
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    img.paste(Image.new("RGBA", (s, s), BG), (0, 0), mask)
    # gauge() supersamples internally, so ask it for the full s and downscale once.
    img.alpha_composite(gauge(s, needle_deg=42.0))
    return img.resize((size, size), Image.LANCZOS)


def tray_template(size: int) -> Image.Image:
    """Monochrome + alpha: macOS treats it as a template, Linux themes it."""
    gauge_img = gauge(size, needle_deg=42.0)
    alpha = gauge_img.getchannel("A")
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.putalpha(alpha)
    return out


def main() -> None:
    os.makedirs(ICON_DIR, exist_ok=True)

    app_icon(512).save(os.path.join(ICON_DIR, "icon.png"))
    for size in (32, 128, 256, 512):
        app_icon(size).save(os.path.join(ICON_DIR, f"{size}x{size}.png"))
    app_icon(1024).save(os.path.join(ICON_DIR, "icon-1024.png"))
    tray_template(22).save(os.path.join(ICON_DIR, "tray.png"))
    tray_template(44).save(os.path.join(ICON_DIR, "tray@2x.png"))
    # Raw RGBA for the Rust side: Tauri's Image::new_owned takes RGBA bytes, and
    # decoding a PNG at runtime would need an image-decoding dependency.
    with open(os.path.join(ICON_DIR, "tray.rgba"), "wb") as fh:
        fh.write(tray_template(22).tobytes())

    # Windows .ico
    app_icon(256).save(
        os.path.join(ICON_DIR, "icon.ico"),
        sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )

    # macOS .icns via iconutil
    if shutil.which("iconutil"):
        with tempfile.TemporaryDirectory() as tmp:
            iconset = os.path.join(tmp, "icon.iconset")
            os.makedirs(iconset)
            for base, scale in ((16, 1), (32, 2), (128, 1), (256, 2), (512, 2)):
                name = f"icon_{base}x{base}.png" if scale == 1 else f"icon_{base}x{base}@2x.png"
                app_icon(base).save(os.path.join(iconset, name))
            icns = os.path.join(ICON_DIR, "icon.icns")
            if os.path.exists(icns):
                os.remove(icns)
            subprocess.run(
                ["iconutil", "-c", "icns", iconset, "-o", icns], check=True
            )
    else:
        print("iconutil not found: skipped .icns (macOS-only build step)")

    print(f"icons written to {ICON_DIR}")


if __name__ == "__main__":
    main()
