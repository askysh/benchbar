#!/usr/bin/env python3
"""app-icon.py: draws the layers of macos/BenchBar/Resources/AppIcon.icon.

The icon is the menu bar runner (a park bench running, BuiltInRunners.swift)
as Icon Composer layers: bench and legs in glass, eyes solid, speed lines
behind. icon.json holds the background and the glass settings; open the
.icon in Icon Composer to tune it. Run from the repository root.
"""
import math
import os

OUT = "macos/BenchBar/Resources/AppIcon.icon/Assets"
S = 40.0                    # points per runner unit (the runner is 24 units wide)
LEAN = math.radians(-12)    # leaning into the run
PIVOT = (9, 6.6)
CENTER = (8.2, 7.0)
WHITE = "#FFFFFF"


def point(p, lean=True):
    x, y = p
    if lean:
        dx, dy = x - PIVOT[0], y - PIVOT[1]
        c, s = math.cos(LEAN), math.sin(LEAN)
        x, y = PIVOT[0] + dx * c - dy * s, PIVOT[1] + dx * s + dy * c
    return (512 + (x - CENTER[0]) * S, 512 - (y - CENTER[1]) * S)


def rounded_rect(x, y, w, h, r):
    pts = []
    for cx, cy, a0 in [(x + w - r, y + h - r, 0), (x + r, y + h - r, 90), (x + r, y + r, 180), (x + w - r, y + r, 270)]:
        for k in range(0, 91, 10):
            a = math.radians(a0 + k)
            pts.append(point((cx + r * math.cos(a), cy + r * math.sin(a))))
    return "M" + " L".join(f"{px:.1f},{py:.1f}" for px, py in pts) + " Z"


def leg(hip, thigh_deg, shin_deg, thigh=3.2, shin=3.4):
    a = math.radians(thigh_deg)
    knee = (hip[0] + thigh * math.sin(a), hip[1] - thigh * math.cos(a))
    b = math.radians(shin_deg)
    foot = (knee[0] + shin * math.sin(b), knee[1] - shin * math.cos(b))
    return "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in [point(hip), point(knee), point(foot)])


def write(name, body):
    with open(os.path.join(OUT, name), "w") as f:
        f.write(f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">{body}</svg>\n')


def main():
    os.makedirs(OUT, exist_ok=True)
    bench = " ".join([
        rounded_rect(2.2, 6.4, 13.6, 2.4, 0.9),    # seat
        rounded_rect(3.4, 8.6, 1.6, 1.6, 0.3),     # posts
        rounded_rect(13.0, 8.6, 1.6, 1.6, 0.3),
        rounded_rect(2.6, 10.0, 12.8, 5.4, 1.7),   # backrest
    ])
    write("bench.svg", f'<path d="{bench}" fill="{WHITE}"/>')
    eyes = ""
    for e in [(10.9, 12.6), (13.6, 12.6)]:
        x, y = point(e)
        eyes += f'<ellipse cx="{x:.1f}" cy="{y:.1f}" rx="{0.6 * S:.1f}" ry="{0.95 * S:.1f}" transform="rotate(12 {x:.1f} {y:.1f})" fill="#0B2A4A"/>'
    write("eyes.svg", eyes)
    write("legs.svg", f'<g fill="none" stroke="{WHITE}" stroke-width="{2.0 * S:.1f}" stroke-linecap="round" stroke-linejoin="round">'
                      f'<path d="{leg((6.6, 6.9), -38, -115)}"/><path d="{leg((11.2, 6.9), 52, 8)}"/></g>')
    lines = ""
    for y, x0, x1 in [(13.2, -1.2, 0.6), (10.6, -2.0, 0.0), (8.0, -1.0, 0.8)]:
        a, b = point((x0, y), False), point((x1, y), False)
        lines += (f'<line x1="{a[0]:.1f}" y1="{a[1]:.1f}" x2="{b[0]:.1f}" y2="{b[1]:.1f}" '
                  f'stroke="{WHITE}" stroke-width="{0.9 * S:.1f}" stroke-linecap="round"/>')
    write("speed.svg", lines)


if __name__ == "__main__":
    main()
