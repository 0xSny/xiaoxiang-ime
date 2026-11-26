#!/usr/bin/env python3
"""Draws the app icon (1024x1024) and writes the asset catalog. Pillow only, no external assets."""
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFont

OUT = sys.argv[1] if len(sys.argv) > 1 else "App/Assets.xcassets"
S = 1024


def lerp(a, b, t):
    return int(a + (b - a) * t)


def gradient():
    img = Image.new("RGB", (S, S))
    px = img.load()
    c1, c2 = (74, 144, 255), (28, 196, 190)   # blue -> teal
    for y in range(S):
        for x in range(S):
            t = (x * 0.35 + y * 0.65) / S
            px[x, y] = (lerp(c1[0], c2[0], t), lerp(c1[1], c2[1], t), lerp(c1[2], c2[2], t))
    return img


def find_font(size):
    cands = [
        "/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/STHeiti Medium.ttc",
        "/System/Library/Fonts/Hiragino Sans GB.ttc", "/Library/Fonts/Arial Unicode.ttf",
        "C:/Windows/Fonts/msyhbd.ttc", "C:/Windows/Fonts/msyh.ttc", "/usr/share/fonts/truetype/noto/NotoSansCJK-Bold.ttc",
    ]
    for p in cands:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                continue
    return None


def main():
    img = gradient().convert("RGBA")
    d = ImageDraw.Draw(img, "RGBA")
    # soft keyboard plate
    plate = (112, 300, S - 112, S - 150)
    d.rounded_rectangle((plate[0], plate[1] + 14, plate[2], plate[3] + 14), radius=70, fill=(0, 40, 90, 70))
    d.rounded_rectangle(plate, radius=70, fill=(255, 255, 255, 235))
    # key caps (3 rows)
    rows = [10, 9, 7]
    x0, x1 = plate[0] + 46, plate[2] - 46
    y = plate[1] + 56
    kh, gap = 86, 22
    for ri, n in enumerate(rows):
        total_w = x1 - x0
        kw = (total_w - gap * 9) / 10
        start = x0 + (total_w - (n * kw + (n - 1) * gap)) / 2
        for i in range(n):
            kx = start + i * (kw + gap)
            col = (214, 228, 250, 255) if (ri + i) % 5 else (74, 144, 255, 255)
            d.rounded_rectangle((kx, y, kx + kw, y + kh), radius=18, fill=col)
        y += kh + gap
    # space bar
    d.rounded_rectangle((x0 + 150, y, x1 - 150, y + kh), radius=18, fill=(214, 228, 250, 255))
    # glyph above the keyboard
    f = find_font(300)
    if f is not None:
        txt = "象"
        bbox = d.textbbox((0, 0), txt, font=f)
        tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
        d.text(((S - tw) / 2 - bbox[0], 40 - bbox[1] + 8), txt, font=f, fill=(255, 255, 255, 255))
    else:
        d.ellipse((S / 2 - 90, 70, S / 2 + 90, 250), fill=(255, 255, 255, 255))
    rgb = Image.new("RGB", (S, S), (255, 255, 255))
    rgb.paste(img, mask=img.split()[3])
    set_dir = os.path.join(OUT, "AppIcon.appiconset")
    os.makedirs(set_dir, exist_ok=True)
    rgb.save(os.path.join(set_dir, "icon-1024.png"), "PNG")
    with open(os.path.join(set_dir, "Contents.json"), "w", encoding="utf-8") as fh:
        json.dump({"images": [{"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
                   "info": {"author": "xcode", "version": 1}}, fh, indent=2)
    with open(os.path.join(OUT, "Contents.json"), "w", encoding="utf-8") as fh:
        json.dump({"info": {"author": "xcode", "version": 1}}, fh, indent=2)
    os.makedirs("Resources", exist_ok=True)
    rgb.resize((256, 256), Image.LANCZOS).save(os.path.join("Resources", "icon.png"))
    print("icon written to", set_dir)


if __name__ == "__main__":
    main()
