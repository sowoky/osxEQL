#!/usr/bin/env python3
"""osxEQL app icon — self-contained generator.

Emits icon.svg (1024x1024): a faceted Norrath crystal with a gold orbital ring on
a twilight-indigo macOS squircle (EQ's blue+gold identity). Render + install via:

    uv run python generate.py
    rsvg-convert -w 1024 -h 1024 icon.svg -o icon.png
    bash build_icns.sh icon.png      # builds AppIcon.icns + installs into ~/Desktop/osxEQL.app

Design picked from 4 candidates (crystal / crystal+ring / sword / moon) ranked cold
by an independent critic; this is the winner with its 4 fixes applied (thicker/brighter
ring, lifted lower facets, flat culet instead of a needle tip, single focal sparkle).
"""
import math, os

SZ = 1024
CX = CY = SZ / 2
OUT = os.path.dirname(os.path.abspath(__file__))
P = lambda *pp: " ".join(f"{x:.1f},{y:.1f}" for x, y in pp)


def squircle_path(cx, cy, a, n=5.0, steps=288):
    """Superellipse (Lamé curve) ~ the macOS Big Sur squircle. a = half-extent."""
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = cx + a * math.copysign(abs(ct) ** (2.0 / n), ct)
        y = cy + a * math.copysign(abs(st) ** (2.0 / n), st)
        pts.append((x, y))
    return "M " + " L ".join(f"{x:.2f},{y:.2f}" for x, y in pts) + " Z"


def star(cx, cy, r, rot=0):
    pts = []
    for k in range(8):
        ang = math.radians(rot + k * 45)
        rad = r if k % 2 == 0 else r * 0.32
        pts.append((cx + rad * math.cos(ang), cy + rad * math.sin(ang)))
    return "M " + " L ".join(f"{x:.2f},{y:.2f}" for x, y in pts) + " Z"


SQ = squircle_path(CX, CY, 430)

DEFS = f"""
  <defs>
    <radialGradient id="bg" cx="50%" cy="34%" r="82%">
      <stop offset="0%" stop-color="#2a3f8f"/><stop offset="46%" stop-color="#142158"/>
      <stop offset="100%" stop-color="#080b22"/></radialGradient>
    <radialGradient id="vig" cx="50%" cy="46%" r="72%">
      <stop offset="62%" stop-color="#000" stop-opacity="0"/>
      <stop offset="100%" stop-color="#000" stop-opacity="0.55"/></radialGradient>
    <linearGradient id="topsheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#fff" stop-opacity="0.16"/>
      <stop offset="26%" stop-color="#fff" stop-opacity="0.04"/>
      <stop offset="55%" stop-color="#fff" stop-opacity="0"/></linearGradient>
    <filter id="dropshadow" x="-30%" y="-30%" width="160%" height="170%">
      <feDropShadow dx="0" dy="22" stdDev="26" flood-color="#000" flood-opacity="0.45"/></filter>
    <filter id="soft" x="-80%" y="-80%" width="260%" height="260%"><feGaussianBlur stdDev="34"/></filter>
    <linearGradient id="cBright" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#e8fcff"/><stop offset="100%" stop-color="#46d2f4"/></linearGradient>
    <linearGradient id="cMid" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#69dbf6"/><stop offset="100%" stop-color="#199ad0"/></linearGradient>
    <linearGradient id="cDark" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#34b3df"/><stop offset="100%" stop-color="#1378a8"/></linearGradient>
    <linearGradient id="cDeep" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#2aa6d6"/><stop offset="100%" stop-color="#11689a"/></linearGradient>
    <radialGradient id="cCore" cx="50%" cy="50%" r="52%">
      <stop offset="0%" stop-color="#fff" stop-opacity="0.95"/>
      <stop offset="42%" stop-color="#c8f4ff" stop-opacity="0.5"/>
      <stop offset="100%" stop-color="#c8f4ff" stop-opacity="0"/></radialGradient>
    <radialGradient id="cHalo" cx="50%" cy="52%" r="50%">
      <stop offset="0%" stop-color="#46e6ff" stop-opacity="0.95"/>
      <stop offset="100%" stop-color="#46e6ff" stop-opacity="0"/></radialGradient>
    <linearGradient id="gold2" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#ffefb0"/><stop offset="48%" stop-color="#f3bf48"/>
      <stop offset="100%" stop-color="#aa7016"/></linearGradient>
  </defs>"""

TOP=(512,228); UL=(370,394); UR=(654,394); L=(338,562); R=(686,562)
LL=(436,716); LR=(588,716); MIDT=(512,394); MIDB=(512,712); BL=(484,792); BR=(540,792)

ART = f"""
    <ellipse cx="512" cy="516" rx="322" ry="346" fill="url(#cHalo)" filter="url(#soft)"/>
    <g transform="rotate(-18 512 516)">
      <ellipse cx="512" cy="516" rx="372" ry="156" fill="none" stroke="url(#gold2)" stroke-width="13" stroke-opacity="0.97"/>
      <ellipse cx="512" cy="516" rx="372" ry="156" fill="none" stroke="#fff4cc" stroke-width="3" stroke-opacity="0.6"/>
    </g>
    <polygon points="{P(TOP,UR,MIDT)}" fill="url(#cBright)"/>
    <polygon points="{P(TOP,MIDT,UL)}" fill="url(#cMid)"/>
    <polygon points="{P(UL,MIDT,L)}" fill="url(#cDark)"/>
    <polygon points="{P(MIDT,UR,R)}" fill="url(#cMid)"/>
    <polygon points="{P(MIDT,R,MIDB,L)}" fill="url(#cBright)" opacity="0.95"/>
    <polygon points="{P(L,MIDB,LL)}" fill="url(#cDeep)"/>
    <polygon points="{P(MIDB,R,LR)}" fill="url(#cDark)"/>
    <polygon points="{P(LL,MIDB,BL)}" fill="url(#cMid)" opacity="0.9"/>
    <polygon points="{P(MIDB,LR,BR)}" fill="url(#cDeep)"/>
    <polygon points="{P(LL,BL,BR,LR)}" fill="url(#cBright)" opacity="0.7"/>
    <polygon points="{P(BL,MIDB,BR)}" fill="url(#cMid)" opacity="0.75"/>
    <ellipse cx="512" cy="512" rx="128" ry="188" fill="url(#cCore)"/>
    <polyline points="{P(TOP,MIDT,MIDB)}" fill="none" stroke="#f4feff" stroke-opacity="0.5" stroke-width="3"/>
    <polyline points="{P(UL,TOP,UR)}" fill="none" stroke="#fff" stroke-opacity="0.95" stroke-width="7"/>
    <polyline points="{P(UR,R,LR,BR)}" fill="none" stroke="#0a4669" stroke-opacity="0.4" stroke-width="4"/>
    <path d="{star(668,344,40,12)}" fill="#fff"/>
    <path d="{star(668,344,18,12)}" fill="#bfefff" opacity="0.9"/>"""

SVG = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{SZ}" height="{SZ}" viewBox="0 0 {SZ} {SZ}">
{DEFS}
  <g filter="url(#dropshadow)"><path d="{SQ}" fill="url(#bg)"/></g>
  <clipPath id="clip"><path d="{SQ}"/></clipPath>
  <g clip-path="url(#clip)">
    <rect width="{SZ}" height="{SZ}" fill="url(#bg)"/>
    {ART}
    <rect width="{SZ}" height="{SZ}" fill="url(#vig)"/>
    <path d="{SQ}" fill="url(#topsheen)"/>
  </g>
  <path d="{SQ}" fill="none" stroke="#9fb6ff" stroke-opacity="0.18" stroke-width="3"/>
</svg>"""

if __name__ == "__main__":
    with open(os.path.join(OUT, "icon.svg"), "w") as f:
        f.write(SVG)
    print("wrote icon.svg")
