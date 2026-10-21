#!/usr/bin/env python3
"""Generate the Ovid Si Android launcher and splash assets.

The mark is a rounded-square "ring" (the workspace) with a small violet rounded
square (the agent) inside it, on the approved obsidian/violet palette. Every
raster layer and the vector drawable are emitted from the same geometry below,
so they cannot drift; ``--check`` fails when the tree does not match.

Mask safety: an adaptive icon's 108 dp canvas is only guaranteed visible inside
the central 66 dp circle (many launchers mask tighter than the 72 dp square).
The ring's outer bounds are therefore kept inside that circle: for a rounded
square of side W and outer corner radius r, the farthest point from the centre
is (W/2 - r) * sqrt(2) + r, which must be <= 33 dp for a 66 dp circle. With
W = 56 dp and r = 16.8 dp that bound is 32.64 dp, so no mask cuts a corner.

Outputs:

  res/mipmap-<density>/ic_launcher.png              legacy icon, Paper plate
  res/mipmap-<density>/ic_launcher_foreground.png   adaptive foreground, 108 dp
  res/mipmap-<density>/ic_launcher_monochrome.png   Android 13 themed layer
  res/drawable/ic_launcher_foreground.xml           the mark as a vector
  res/mipmap-anydpi-v26/ic_launcher.xml             adaptive icon
  res/mipmap-anydpi-v33/ic_launcher.xml             adaptive icon + monochrome
  res/drawable/launch_background.xml                splash, flat #0E0E10
  res/values-v31/styles.xml                         Android 12+ splash theme
  res/values-night-v31/styles.xml                   Android 12+ splash theme

Usage:
    python3 tool/gen_launcher_icons.py [--check] [--quiet]

Requires Pillow (already used by tool/ui_screenshot_review.py).
"""

from __future__ import annotations

import argparse
import io
import sys
from pathlib import Path

from PIL import Image, ImageDraw

# --- Brand -----------------------------------------------------------------

PAPER = "#0E0E10"  # res/values/colors.xml <color name="paper">
INK = "#EDEDF2"  # ring, <color name="ink">
VIOLET = "#7C5CFF"  # agent square, <color name="signal_red">
WHITE = "#FFFFFF"  # the monochrome layer is tinted by the system

# --- Mark geometry, normalised to the 108 x 108 adaptive-icon viewport -------

VIEWPORT = 108.0
RING_OUTER_MIN = 26.0
RING_OUTER_MAX = 82.0
RING_OUTER_RADIUS = 16.8
RING_STROKE = 7.2
AGENT_MIN = 47.6
AGENT_MAX = 60.4
AGENT_RADIUS = 4.0

# Centreline of a centred stroke, which is what the vector path traces.
RING_MIN = RING_OUTER_MIN + RING_STROKE / 2.0  # 29.6
RING_MAX = RING_OUTER_MAX - RING_STROKE / 2.0  # 78.4
RING_RADIUS = RING_OUTER_RADIUS - RING_STROKE / 2.0  # 13.2

# --- Sizes -----------------------------------------------------------------

DENSITIES = {
    "mdpi": 1.0,
    "hdpi": 1.5,
    "xhdpi": 2.0,
    "xxhdpi": 3.0,
    "xxxhdpi": 4.0,
}
LEGACY_DP = 48.0  # legacy square icon, artwork 70 % of the plate
LEGACY_MARK_FILL = 0.70
LEGACY_PLATE_RADIUS = 0.22  # of the plate side, so it matches a launcher mask
ADAPTIVE_DP = 108.0
SPLASH_MARK_DP = 176
SUPERSAMPLE = 4

ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / "android" / "app" / "src" / "main" / "res"


def _rgba(value: str) -> tuple[int, int, int, int]:
    value = value.lstrip("#")
    return tuple(int(value[i : i + 2], 16) for i in (0, 2, 4)) + (255,)  # type: ignore[return-value]


def _px(value: float, side: int) -> float:
    """Viewport units -> pixels for a canvas of ``side`` px."""
    return value / VIEWPORT * side


def render_mark(side_px: int, ring: str, agent: str) -> Image.Image:
    """The mark alone on a transparent 108 dp square, supersampled."""
    big = side_px * SUPERSAMPLE
    image = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle(
        tuple(_px(v, big) for v in (RING_OUTER_MIN, RING_OUTER_MIN, RING_OUTER_MAX, RING_OUTER_MAX)),
        radius=_px(RING_OUTER_RADIUS, big),
        outline=_rgba(ring),
        width=max(1, round(_px(RING_STROKE, big))),
    )
    draw.rounded_rectangle(
        tuple(_px(v, big) for v in (AGENT_MIN, AGENT_MIN, AGENT_MAX, AGENT_MAX)),
        radius=_px(AGENT_RADIUS, big),
        fill=_rgba(agent),
    )
    return image.resize((side_px, side_px), Image.LANCZOS)


def render_legacy(side_px: int) -> Image.Image:
    """Legacy icon: rounded Paper plate with the mark at 70 % of its width.

    Legacy icons are not masked, so the mark is enlarged past the adaptive
    safe zone; the plate corners keep it consistent with masked launchers.
    """
    big = side_px * SUPERSAMPLE
    plate = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(plate).rounded_rectangle(
        (0, 0, big - 1, big - 1),
        radius=LEGACY_PLATE_RADIUS * big,
        fill=_rgba(PAPER),
    )
    # The mark's own canvas is 108 dp wide but the ring is only 62 dp of it;
    # scale the whole square so the ring lands at LEGACY_MARK_FILL of the plate.
    ring_fraction = (RING_OUTER_MAX - RING_OUTER_MIN) / VIEWPORT
    mark_side = round(big * LEGACY_MARK_FILL / ring_fraction)
    if mark_side % 2 != big % 2:
        mark_side += 1
    mark = render_mark(mark_side, INK, VIOLET)
    offset = (big - mark_side) // 2
    plate.paste(mark, (offset, offset), mark)
    return plate.resize((side_px, side_px), Image.LANCZOS)


def _png(image: Image.Image) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, format="PNG", optimize=True)
    return buffer.getvalue()


# --- XML -------------------------------------------------------------------


def vector_xml() -> str:
    """The mark as a vector drawable; same geometry as the rasterised layers."""
    x1, y1 = RING_MIN, RING_MIN
    x2, y2 = RING_MAX, RING_MAX
    r = RING_RADIUS

    def n(value: float) -> str:
        return f"{value:.2f}".rstrip("0").rstrip(".")

    ring = (
        f"M{n(x1 + r)},{n(y1)} L{n(x2 - r)},{n(y1)} "
        f"A{n(r)},{n(r)} 0 0 1 {n(x2)},{n(y1 + r)} "
        f"L{n(x2)},{n(y2 - r)} "
        f"A{n(r)},{n(r)} 0 0 1 {n(x2 - r)},{n(y2)} "
        f"L{n(x1 + r)},{n(y2)} "
        f"A{n(r)},{n(r)} 0 0 1 {n(x1)},{n(y2 - r)} "
        f"L{n(x1)},{n(y1 + r)} "
        f"A{n(r)},{n(r)} 0 0 1 {n(x1 + r)},{n(y1)} Z"
    )
    ax1, ay1, ax2, ay2 = AGENT_MIN, AGENT_MIN, AGENT_MAX, AGENT_MAX
    ar = AGENT_RADIUS
    agent = (
        f"M{n(ax1 + ar)},{n(ay1)} L{n(ax2 - ar)},{n(ay1)} "
        f"A{n(ar)},{n(ar)} 0 0 1 {n(ax2)},{n(ay1 + ar)} "
        f"L{n(ax2)},{n(ay2 - ar)} "
        f"A{n(ar)},{n(ar)} 0 0 1 {n(ax2 - ar)},{n(ay2)} "
        f"L{n(ax1 + ar)},{n(ay2)} "
        f"A{n(ar)},{n(ar)} 0 0 1 {n(ax1)},{n(ay2 - ar)} "
        f"L{n(ax1)},{n(ay1 + ar)} "
        f"A{n(ar)},{n(ar)} 0 0 1 {n(ax1 + ar)},{n(ay1)} Z"
    )
    return f"""<?xml version="1.0" encoding="utf-8"?>
<!-- Ovid Si mark: the ring (workspace) + violet agent square.
     GENERATED by tool/gen_launcher_icons.py; edit the geometry there.
     The 56 dp ring sits inside the 66 dp safe circle of the 108 dp adaptive
     canvas, so no launcher mask cuts a corner; the rasterised adaptive and
     monochrome layers are produced from this same geometry. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
    <path
        android:fillColor="#00000000"
        android:strokeColor="{INK}"
        android:strokeWidth="{RING_STROKE}"
        android:strokeLineJoin="round"
        android:pathData="{ring}" />
    <path
        android:fillColor="{VIOLET}"
        android:pathData="{agent}" />
</vector>
"""


ADAPTIVE_XML = """<?xml version="1.0" encoding="utf-8"?>
<!-- Ovid Si adaptive icon: Paper plate with the generated Ring + agent square
     foreground. Regenerate every layer with tool/gen_launcher_icons.py. -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/paper" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
"""

ADAPTIVE_MONOCHROME_XML = """<?xml version="1.0" encoding="utf-8"?>
<!-- Android 13+ themed icon: the system tints this single-colour layer with the
     user's wallpaper palette, so it carries no brand colour of its own. -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/paper" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />
</adaptive-icon>
"""

SPLASH_XML = f"""<?xml version="1.0" encoding="utf-8"?>
<!-- Ovid Si splash: flat #0E0E10 (Paper) with the brand mark centred. The mark
     is the vector drawable so it stays crisp at any density. -->
<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <item android:drawable="@color/paper" />
    <item
        android:width="{SPLASH_MARK_DP}dp"
        android:height="{SPLASH_MARK_DP}dp"
        android:gravity="center"
        android:drawable="@drawable/ic_launcher_foreground" />
</layer-list>
"""

SPLASH_THEME_XML = """<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- Android 12+ paints the system splash from the window theme instead of
         windowBackground. Keep it on the same #0E0E10 Paper plate and show the
         brand mark, so the cold-start frame matches the Flutter splash. -->
    <style name="LaunchTheme" parent="{parent}">
        <item name="android:windowBackground">@drawable/launch_background</item>
        <item name="android:windowSplashScreenBackground">@color/paper</item>
        <item name="android:windowSplashScreenAnimatedIcon">@drawable/ic_launcher_foreground</item>
    </style>
</resources>
"""


def outputs() -> dict[Path, bytes]:
    """Build every asset in memory so --check and writes share one source."""
    files: dict[Path, bytes] = {}
    for density, factor in DENSITIES.items():
        adaptive_px = round(ADAPTIVE_DP * factor)
        files[RES / f"mipmap-{density}" / "ic_launcher.png"] = _png(
            render_legacy(round(LEGACY_DP * factor))
        )
        files[RES / f"mipmap-{density}" / "ic_launcher_foreground.png"] = _png(
            render_mark(adaptive_px, INK, VIOLET)
        )
        files[RES / f"mipmap-{density}" / "ic_launcher_monochrome.png"] = _png(
            render_mark(adaptive_px, WHITE, WHITE)
        )

    files[RES / "drawable" / "ic_launcher_foreground.xml"] = vector_xml().encode()
    files[RES / "mipmap-anydpi-v26" / "ic_launcher.xml"] = ADAPTIVE_XML.encode()
    files[RES / "mipmap-anydpi-v33" / "ic_launcher.xml"] = ADAPTIVE_MONOCHROME_XML.encode()
    files[RES / "drawable" / "launch_background.xml"] = SPLASH_XML.encode()
    files[RES / "values-v31" / "styles.xml"] = SPLASH_THEME_XML.format(
        parent="@android:style/Theme.Light.NoTitleBar"
    ).encode()
    files[RES / "values-night-v31" / "styles.xml"] = SPLASH_THEME_XML.format(
        parent="@android:style/Theme.Black.NoTitleBar"
    ).encode()
    return files


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail if any generated file is missing or differs; writes nothing",
    )
    parser.add_argument("--quiet", action="store_true", help="only print failures")
    args = parser.parse_args()

    files = outputs()
    if args.check:
        stale = []
        for path, expected in files.items():
            rel = path.relative_to(ROOT)
            if not path.is_file():
                stale.append(f"missing {rel}")
            elif path.read_bytes() != expected:
                stale.append(f"stale   {rel}")
        if stale:
            print(
                "launcher assets are out of date; run tool/gen_launcher_icons.py",
                file=sys.stderr,
            )
            for line in stale:
                print(f"  {line}", file=sys.stderr)
            return 1
        if not args.quiet:
            print(f"launcher assets match the generator ({len(files)} files)")
        return 0

    for path, data in files.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        if not args.quiet:
            print(path.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
