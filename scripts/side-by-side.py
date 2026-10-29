# Copyright (c) 2026 Colin Tay
# SPDX-License-Identifier: MIT
"""Puts each ArtGallery scene rendered on macOS next to the same scene rendered on Windows.

    python3 scripts/side-by-side.py <macos dir> <windows dir> <out dir>

For every <scene>.png in the macOS directory, writes <out dir>/<scene>.png: the macOS render on the left, the
Windows one on the right, under a title. Small scenes are enlarged by a whole factor (nearest neighbour, so every
pixel stays visible) to make them easier to compare. Needs Pillow (CI pins the version).
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

BACKGROUND = (0x0A, 0x0E, 0x26)
DIVIDER = (0x6A, 0x78, 0xD8)
TEXT = (0xE8, 0xEE, 0xFF)
GAP = 24
TITLE_HEIGHT = 56
TARGET_WIDTH = 1200  # enlarge until one side is about this wide (at most 4x)


def font(size):
    try:
        return ImageFont.load_default(size=size)
    except TypeError:  # Pillow without FreeType: the bitmap font
        return ImageFont.load_default()


def stitch(name, mac, win):
    scale = max(1, min(4, TARGET_WIDTH // max(mac.width, win.width)))
    if scale > 1:
        mac = mac.resize((mac.width * scale, mac.height * scale), Image.NEAREST)
        win = win.resize((win.width * scale, win.height * scale), Image.NEAREST)
    width = mac.width + win.width + GAP * 3
    height = max(mac.height, win.height) + TITLE_HEIGHT + GAP * 2
    out = Image.new("RGB", (width, height), BACKGROUND)
    draw = ImageDraw.Draw(out)
    zoom = f" (enlarged {scale}x)" if scale > 1 else ""
    draw.text((GAP, 12), f"{name}{zoom}", fill=TEXT, font=font(22))
    left, right = GAP, GAP * 2 + mac.width
    draw.text((left, TITLE_HEIGHT - 14), "macOS (Core Graphics)", fill=TEXT, font=font(14))
    draw.text((right, TITLE_HEIGHT - 14), "Windows (Direct2D)", fill=TEXT, font=font(14))
    top = TITLE_HEIGHT + GAP
    out.paste(mac.convert("RGB"), (left, top))
    out.paste(win.convert("RGB"), (right, top))
    x = left + mac.width + GAP // 2
    draw.line([(x, TITLE_HEIGHT), (x, height - GAP // 2)], fill=DIVIDER, width=2)
    return out


def main(argv):
    if len(argv) != 4:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    mac_dir, win_dir, out_dir = (Path(a) for a in argv[1:])
    out_dir.mkdir(parents=True, exist_ok=True)
    scenes = sorted(p.name for p in mac_dir.glob("*.png"))
    missing = [s for s in scenes if not (win_dir / s).exists()]
    if not scenes or missing:
        print(f"no scenes in {mac_dir}" if not scenes else f"missing on Windows: {', '.join(missing)}", file=sys.stderr)
        return 1
    for s in scenes:
        with Image.open(mac_dir / s) as mac, Image.open(win_dir / s) as win:
            stitch(Path(s).stem, mac, win).save(out_dir / s)
        print(f"side-by-side: {out_dir / s}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
