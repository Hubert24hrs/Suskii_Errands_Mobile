"""Launcher icons and launch images for Android and iOS, from the design tokens.

The mark is interim: the brand gradient from packages/design-tokens/tokens.json with the bolt
the app shows beside its name. When the client delivers final artwork (RB-15, client action),
replace `draw_mark` or feed the delivered 1024 px master through `from_master` and re-run:

    python3 apps/mobile/tool/brand/generate_icons.py            # needs Pillow

Android's adaptive icon and splash are vector drawables that do not need this script; they
carry the same colours and the same bolt path (res/drawable/ic_launcher_*.xml).
"""

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[4]
APP = ROOT / "apps" / "mobile"
TOKENS = json.loads((ROOT / "packages" / "design-tokens" / "tokens.json").read_text())

GRADIENT = [TOKENS["color"]["brand"]["gradient"]["dark"][i] for i in range(3)]
ON_GRADIENT = TOKENS["color"]["brand"]["onGradient"]["dark"]

# The Material "bolt" glyph on a 24-unit grid, as a polygon.
BOLT = [(11, 21), (10, 21), (11, 14), (7.5, 14), (13, 3), (14, 3), (13, 10), (16.5, 10)]


def _rgb(hex_colour: str) -> tuple[int, int, int]:
    h = hex_colour.lstrip("#")
    return tuple(int(h[i : i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]


def _lerp(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))  # type: ignore[return-value]


def gradient(size: int) -> Image.Image:
    """Top-left to bottom-right through the three token stops."""
    stops = [_rgb(c) for c in GRADIENT]
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            px[x, y] = _lerp(stops[0], stops[1], t * 2) if t < 0.5 else _lerp(stops[1], stops[2], (t - 0.5) * 2)
    return img


def draw_mark(size: int, glyph_fraction: float = 0.58) -> Image.Image:
    """The full-bleed square mark (opaque, as both stores require for the master)."""
    scale = 4  # draw large and downsample for smooth edges
    big = size * scale
    img = gradient(big)
    draw = ImageDraw.Draw(img)
    glyph = big * glyph_fraction
    offset = (big - glyph) / 2
    unit = glyph / 24
    draw.polygon([(offset + x * unit, offset + y * unit) for x, y in BOLT], fill=_rgb(ON_GRADIENT))
    return img.resize((size, size), Image.LANCZOS)


def rounded(img: Image.Image, radius_fraction: float = 0.22) -> Image.Image:
    size = img.size[0]
    mask = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size * 4 - 1, size * 4 - 1), radius=int(size * 4 * radius_fraction), fill=255
    )
    out = img.convert("RGBA")
    out.putalpha(mask.resize((size, size), Image.LANCZOS))
    return out


def android_legacy() -> None:
    """Pre-API-26 launchers (minSdk 24) use these; 26+ use the adaptive vector icon."""
    for density, px in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        out = APP / "android" / "app" / "src" / "main" / "res" / f"mipmap-{density}" / "ic_launcher.png"
        rounded(draw_mark(px)).save(out, optimize=True)


def ios_app_icons() -> None:
    folder = APP / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    contents = json.loads((folder / "Contents.json").read_text())
    for image in contents["images"]:
        points = float(image["size"].split("x")[0])
        px = round(points * int(image["scale"].rstrip("x")))
        # iOS applies its own mask; icons must be square and opaque (no alpha channel).
        draw_mark(px).convert("RGB").save(folder / image["filename"], optimize=True)


def ios_launch_images() -> None:
    """The centred mark on the launch screen, over the LaunchBackground colour set."""
    folder = APP / "ios" / "Runner" / "Assets.xcassets" / "LaunchImage.imageset"
    for scale, name in ((1, "LaunchImage.png"), (2, "LaunchImage@2x.png"), (3, "LaunchImage@3x.png")):
        rounded(draw_mark(96 * scale)).save(folder / name, optimize=True)


if __name__ == "__main__":
    android_legacy()
    ios_app_icons()
    ios_launch_images()
    print("icons written")
