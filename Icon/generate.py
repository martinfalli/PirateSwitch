#!/usr/bin/env python3
"""Generates PirateSwitch's artwork from simple shapes.

Outputs:
  Icon/AppIcon.icon/Assets/flag.svg, pole.svg   Liquid Glass app icon layers
  Resources/AppIcon.icns                          flat fallback for builds without Xcode 26
  Resources/MenuBarFlag*.pdf                      menu bar template images

Requires: pip install shapely cairosvg pillow
Usage:    python3 Icon/generate.py [preview-dir]
"""
import math
import os
import sys

import io

import cairosvg
from PIL import Image
from shapely import affinity
from shapely.geometry import LineString, Point, Polygon
from shapely.ops import unary_union

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


# --- geometry helpers --------------------------------------------------------

def cubic(p0, p1, p2, p3, steps=24):
    pts = []
    for i in range(1, steps + 1):
        t = i / steps
        u = 1 - t
        pts.append((
            u**3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t**3 * p3[0],
            u**3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t**3 * p3[1],
        ))
    return pts


def bezier_shape(start, segments):
    """segments: list of (c1, c2, end) cubic curves or (end,) straight lines."""
    pts = [start]
    for seg in segments:
        pts += cubic(pts[-1], *seg) if len(seg) == 3 else [seg[0]]
    return Polygon(pts).buffer(0)


def ellipse(cx, cy, rx, ry):
    return affinity.translate(affinity.scale(Point(0, 0).buffer(1, 32), rx, ry), cx, cy)


def place(geom, cx, cy, size):
    """Maps a shape drawn in unit space (centered on 0,0) to (cx, cy) at `size`."""
    return affinity.translate(affinity.scale(geom, size, size, origin=(0, 0)), cx, cy)


# --- the motif, in unit space ------------------------------------------------

def skull():
    """Skull outline, roughly 1.04 wide and 1.2 tall, centered on the origin."""
    return bezier_shape((0, -0.62), [
        ((0.30, -0.62), (0.52, -0.42), (0.52, -0.12)),
        ((0.52, 0.10), (0.44, 0.22), (0.40, 0.34)),
        ((0.36, 0.48), (0.22, 0.58), (0.0, 0.58)),
        ((-0.22, 0.58), (-0.36, 0.48), (-0.40, 0.34)),
        ((-0.44, 0.22), (-0.52, 0.10), (-0.52, -0.12)),
        ((-0.52, -0.42), (-0.30, -0.62), (0, -0.62)),
    ])


def skull_features(teeth=True):
    """Eye sockets, nose and teeth: drawn back in flag color inside the skull."""
    parts = [ellipse(-0.21, -0.06, 0.14, 0.13), ellipse(0.21, -0.06, 0.14, 0.13)]
    parts.append(bezier_shape((0, 0.08), [
        ((0.03, 0.08), (0.08, 0.22), (0.07, 0.26)),
        ((0.06, 0.29), (-0.06, 0.29), (-0.07, 0.26)),
        ((-0.08, 0.22), (-0.03, 0.08), (0, 0.08)),
    ]))
    if teeth:
        parts.append(LineString([(-0.20, 0.42), (0.20, 0.42)]).buffer(0.016, cap_style=1))
        for i in range(6):
            x = -0.16 + i * 0.064
            parts.append(LineString([(x, 0.37), (x, 0.47)]).buffer(0.014, cap_style=1))
    return unary_union(parts)


def bone(length, width):
    """A horizontal bone centered on the origin, with knobbly ends."""
    half = length / 2
    knob = width * 0.72
    shape = [LineString([(-half, 0), (half, 0)]).buffer(width / 2, cap_style=2)]
    for x in (-half, half):
        shape += [Point(x, -knob * 0.75).buffer(knob, 24), Point(x, knob * 0.75).buffer(knob, 24)]
    return unary_union(shape)


def crossbones(length=2.0, width=0.13, dy=0.12):
    b = bone(length, width)
    return affinity.translate(
        unary_union([affinity.rotate(b, 32, origin=(0, 0)), affinity.rotate(b, -32, origin=(0, 0))]),
        0, dy)


def jolly_roger(cx, cy, size, teeth=True, bone_length=2.0, bone_width=0.13):
    """Skull and crossbones to cut out of the flag, and the features to put back."""
    cut = place(unary_union([skull(), crossbones(bone_length, bone_width)]), cx, cy, size)
    keep = place(skull_features(teeth), cx, cy, size)
    return cut, keep


def flag(x0, x1, top, bottom, wave):
    """A waving flag attached to a pole at x0."""
    w = x1 - x0
    return bezier_shape((x0, top), [
        ((x0 + w * 0.3, top - wave), (x0 + w * 0.62, top + wave), (x1, top - wave * 0.4)),
        ((x1 + wave * 0.15, top + (bottom - top) * 0.4), (x1 - wave * 0.15, top + (bottom - top) * 0.7),
         (x1, bottom - wave * 0.4)),
        ((x0 + w * 0.62, bottom + wave), (x0 + w * 0.3, bottom - wave), (x0, bottom)),
    ])


# --- output ------------------------------------------------------------------

def path_data(geom, digits):
    polys = [geom] if geom.geom_type == "Polygon" else list(geom.geoms)
    out = []
    for poly in polys:
        for ring in [poly.exterior, *poly.interiors]:
            coords = list(ring.coords)[:-1]
            out.append("M" + " L".join(f"{x:.{digits}f} {y:.{digits}f}" for x, y in coords) + "Z")
    return "".join(out)


def svg(size, layers, digits=1, background=None):
    body = f'<rect width="{size}" height="{size}" fill="{background}"/>' if background else ""
    for geom, color in layers:
        body += f'<path fill="{color}" fill-rule="evenodd" d="{path_data(geom, digits)}"/>'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" '
            f'viewBox="0 0 {size} {size}">{body}</svg>\n')


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def app_icon():
    """1024x1024 canvas. Two layers so Liquid Glass can give them depth."""
    pole = unary_union([
        LineString([(250, 190), (250, 850)]).buffer(18, cap_style=1),
        Point(250, 172).buffer(32, 32),
    ])
    body = flag(262, 850, 232, 668, 64)
    cut, keep = jolly_roger(562, 450, 185)
    return (body - cut) | (keep & body), pole


def squircle(cx, cy, half, n=5, steps=256):
    """Superellipse approximating the macOS icon shape."""
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        pts.append((cx + half * math.copysign(abs(c) ** (2 / n), c),
                    cy + half * math.copysign(abs(s) ** (2 / n), s)))
    return Polygon(pts)


def flat_icon_svg(flag_layer, pole_layer):
    """The same artwork without the glass, on a macOS-shaped tile (824pt on a
    1024 canvas, like Apple's icon template), for the .icns fallback."""
    tile = path_data(squircle(512, 512, 412), 1)
    scale = 824 / 1024
    art = affinity.scale(unary_union([flag_layer, pole_layer]), scale, scale, origin=(512, 512))
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            '<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">'
            '<stop offset="0" stop-color="#2B2B2E"/><stop offset="0.7" stop-color="#000000"/>'
            '</linearGradient></defs>'
            f'<path fill="url(#bg)" d="{tile}"/>'
            f'<path fill="none" stroke="#FFFFFF" stroke-opacity="0.2" stroke-width="4" d="{tile}"/>'
            f'<path fill="#FFFFFF" fill-rule="evenodd" d="{path_data(art, 1)}"/>'
            '</svg>\n')


def menu_bar_glyph(slash, pole):
    """36x36 canvas (18pt @2x), simplified for legibility at menu bar size."""
    if pole:
        body = flag(6.2, 33.2, 6.5, 25, 1.6)
        cut, keep = jolly_roger(19.8, 15.6, 10, teeth=False, bone_length=1.8, bone_width=0.22)
        glyph = (body - cut) | (keep & body) | unary_union([
            LineString([(5.2, 5), (5.2, 33.5)]).buffer(1.35, cap_style=1),
            Point(5.2, 4.2).buffer(2.1, 24),
        ])
    else:
        body = flag(1.5, 34.5, 7, 29, 1.8)
        cut, keep = jolly_roger(18, 18, 11.5, teeth=False, bone_length=1.8, bone_width=0.22)
        glyph = (body - cut) | (keep & body)
    if slash:
        line = LineString([(3, 3.5), (33, 33.5)])
        glyph = (glyph - line.buffer(3.4, cap_style=2)) | line.buffer(1.5, cap_style=1)
    return glyph


def main():
    preview = sys.argv[1] if len(sys.argv) > 1 else None

    flag_layer, pole_layer = app_icon()
    assets = os.path.join(ROOT, "Icon", "AppIcon.icon", "Assets")
    write(os.path.join(assets, "flag.svg"), svg(1024, [(flag_layer, "#FFFFFF")]))
    write(os.path.join(assets, "pole.svg"), svg(1024, [(pole_layer, "#FFFFFF")]))

    flat = cairosvg.svg2png(bytestring=flat_icon_svg(flag_layer, pole_layer).encode())
    icon = Image.open(io.BytesIO(flat))
    icon.save(os.path.join(ROOT, "Resources", "AppIcon.icns"))

    for base, pole in (("MenuBarFlag", True), ("MenuBarFlagOnly", False)):
        for slash in (False, True):
            name = base + ("Slash" if slash else "")
            data = svg(36, [(menu_bar_glyph(slash, pole), "#000000")], digits=2)
            cairosvg.svg2pdf(bytestring=data.encode(), write_to=os.path.join(ROOT, "Resources", name + ".pdf"),
                             output_width=18, output_height=18)
            if preview:
                for px in (18, 36, 144):
                    cairosvg.svg2png(bytestring=data.encode(), write_to=os.path.join(preview, f"{name}-{px}.png"),
                                     output_width=px, output_height=px, background_color="white")

    if preview:
        icon.resize((512, 512), Image.LANCZOS).save(os.path.join(preview, "AppIcon-flat.png"))


if __name__ == "__main__":
    main()
