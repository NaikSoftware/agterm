"""Render agterm's app icon for Linux from master's Icon Composer layer.

macOS shapes the square artwork at runtime ("fill": "automatic"); hicolor themes need the shape baked in,
so the layer is clipped to a rounded square with a little margin, at every size the theme looks up.
Usage: python3 -I scripts/make-icons.py <layer.png> <repo root>
"""
import os
import sys
from PIL import Image, ImageDraw

layer = Image.open(sys.argv[1]).convert("RGBA")
root = sys.argv[2]
big = 1024
art = layer.resize((big, big), Image.LANCZOS)
margin, radius = int(big * 0.06), int(big * 0.2)
mask = Image.new("L", (big, big), 0)
ImageDraw.Draw(mask).rounded_rectangle((margin, margin, big - margin, big - margin), radius, fill=255)
icon = Image.new("RGBA", (big, big), (0, 0, 0, 0))
icon.paste(art, (0, 0), mask)
for size in (16, 22, 24, 32, 48, 64, 128, 256, 512):
    path = f"{root}/resources/icons/hicolor/{size}x{size}/apps/agterm-qt.png"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    icon.resize((size, size), Image.LANCZOS).save(path, optimize=True)
print("icons written")
