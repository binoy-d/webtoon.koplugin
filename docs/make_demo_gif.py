"""Render docs/demo.gif: a simulated e-reader showing webtoon.koplugin's panel-snap glide.

The comic is drawn here from simple shapes (an original character), so the repo ships no
third-party art. The snap points come from kowebtoon's real panel finder, and the refreshes mimic
e-ink: dithered black-and-white fast frames with faint ghosting, then a clean greyscale settle,
plus one periodic full flash.

    python docs/make_demo_gif.py
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from kowebtoon import render  # noqa: E402

W, H = 300, 400                     # simulated screen
BEZEL, CHIN = 22, 46


def font(size):
    for f in ("/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"):
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default(size=size)


def bubble(d, box, text, tail):
    x0, y0, x1, y1 = box
    d.ellipse(box, fill=255, outline=0, width=2)
    d.polygon([tail, ((x0 + x1) // 2 - 8, y1 - 6), ((x0 + x1) // 2 + 8, y1 - 6)], fill=255, outline=0)
    d.line([((x0 + x1) // 2 - 7, y1 - 5), ((x0 + x1) // 2 + 7, y1 - 5)], fill=255, width=3)
    f = font(13)
    lines = text.split("\n")
    ty = (y0 + y1) // 2 - 9 * len(lines)
    for ln in lines:
        tw = d.textlength(ln, font=f)
        d.text(((x0 + x1 - tw) // 2, ty), ln, font=f, fill=0)
        ty += 18


def robot(d, cx, cy, s=1.0, mood="happy"):
    r = int(34 * s)
    d.line([(cx, cy - r), (cx, cy - r - 16 * s)], fill=0, width=3)
    d.ellipse((cx - 5, cy - r - 22 * s, cx + 5, cy - r - 12 * s), fill=0)
    d.rounded_rectangle((cx - r, cy - r, cx + r, cy + r), radius=int(14 * s), fill=225, outline=0, width=3)
    d.rounded_rectangle((cx - r + 8, cy - r + 10, cx + r - 8, cy + 4), radius=8, fill=40)
    ey = cy - r + 22
    for ex in (cx - 12 * s, cx + 12 * s):
        d.ellipse((ex - 5, ey - 5, ex + 5, ey + 5), fill=230)
    if mood == "happy":
        d.arc((cx - 14, cy + 4, cx + 14, cy + 22), 20, 160, fill=0, width=3)
    else:
        d.line([(cx - 10, cy + 14), (cx + 10, cy + 14)], fill=0, width=3)
    d.rounded_rectangle((cx - r + 6, cy + r, cx + r - 6, cy + r + int(40 * s)), radius=10, fill=150, outline=0, width=3)


def comic():
    """A tall strip: panels separated by blank gutters."""
    panels = [
        ("sky", 230), ("hello", 300), ("coffee", 260), ("rain", 300), ("umbrella", 280), ("end", 220),
    ]
    gutter = 46
    total = sum(h for _, h in panels) + gutter * (len(panels) + 1)
    im = Image.new("L", (W, total), 255)
    d = ImageDraw.Draw(im)
    y = gutter
    for kind, h in panels:
        box = (14, y, W - 14, y + h)
        if kind == "sky":
            d.rectangle(box, fill=205, outline=0, width=2)
            d.ellipse((W - 90, y + 26, W - 40, y + 76), fill=255, outline=0, width=2)
            d.polygon([(14, y + h), (90, y + 130), (170, y + h)], fill=120, outline=0)
            d.polygon([(110, y + h), (210, y + 110), (W - 14, y + h)], fill=90, outline=0)
            d.text((28, y + 20), "Tuesday.", font=font(18), fill=0)
        elif kind == "hello":
            d.rectangle(box, fill=245, outline=0, width=2)
            robot(d, W // 2, y + 170)
            bubble(d, (60, y - 28, W - 40, y + 50), "Good morning,\nsmall world!", (W // 2 - 10, y + 92))
        elif kind == "coffee":
            d.rectangle(box, fill=180, outline=0, width=2)
            d.rounded_rectangle((W // 2 - 40, y + 90, W // 2 + 40, y + 200), radius=10, fill=255, outline=0, width=3)
            d.arc((W // 2 + 28, y + 115, W // 2 + 68, y + 165), 270, 90, fill=0, width=4)
            for i in range(3):
                d.arc((W // 2 - 30 + i * 22, y + 40, W // 2 - 10 + i * 22, y + 85), 200, 340, fill=60, width=3)
            d.text((30, y + 220), "Fuel acquired.", font=font(16), fill=0)
        elif kind == "rain":
            d.rectangle(box, fill=150, outline=0, width=2)
            for i in range(40):
                x = 20 + (i * 37) % (W - 40)
                yy = y + 10 + (i * 53) % (h - 30)
                d.line([(x, yy), (x - 6, yy + 16)], fill=255, width=2)
            robot(d, W // 2, y + 200, 0.8, mood="flat")
            bubble(d, (40, y + 18, W - 60, y + 88), "...oh.", (W // 2, y + 140))
        elif kind == "umbrella":
            d.rectangle(box, fill=230, outline=0, width=2)
            d.pieslice((W // 2 - 95, y + 30, W // 2 + 95, y + 190), 180, 360, fill=70, outline=0, width=3)
            d.line([(W // 2, y + 110), (W // 2, y + 240)], fill=0, width=4)
            d.arc((W // 2, y + 225, W // 2 + 24, y + 255), 0, 180, fill=0, width=4)
            robot(d, W // 2 - 50, y + 190, 0.6)
            bubble(d, (W // 2 + 10, y + 150, W - 20, y + 222), "Prepared!", (W // 2 + 20, y + 190))
        else:
            d.rectangle(box, fill=255, outline=0, width=2)
            d.text((W // 2 - 70, y + h // 2 - 30), "the end", font=font(28), fill=0)
            d.text((W // 2 - 88, y + h // 2 + 10), "(next episode opens)", font=font(14), fill=90)
        y += h + gutter
    return im


def dither(im):
    return im.convert("1", dither=Image.FLOYDSTEINBERG).convert("L")


def device(screen, tap=False):
    out = Image.new("L", (W + 2 * BEZEL, H + BEZEL + CHIN), 38)
    d = ImageDraw.Draw(out)
    d.rounded_rectangle((0, 0, out.width - 1, out.height - 1), radius=26, fill=38)
    out.paste(screen, (BEZEL, BEZEL))
    if tap:
        cx, cy = BEZEL + W - 50, BEZEL + H - 60
        d.ellipse((cx - 22, cy - 22, cx + 22, cy + 22), outline=0, width=3)
        d.ellipse((cx - 8, cy - 8, cx + 8, cy + 8), fill=0)
    return out


def main():
    strip = comic()
    spread, _ = render.row_profile(strip)
    gaps = render.find_gutters(spread, W)
    view = lambda top: strip.crop((0, top, W, top + H))   # noqa: E731

    frames, durations = [], []

    def add(img, ms, tap=False):
        frames.append(device(img, tap)); durations.append(ms)

    top, glide = 0, 0
    add(view(top), 1400)
    while True:
        # the plugin's rule: scroll so the last gap still on screen becomes the top
        on = [g for g in gaps if top + 0.2 * H < g <= top + H]
        target = min(on[-1] if on else top + int(0.85 * H), strip.height - H)
        if target <= top:
            break
        glide += 1
        add(view(top), 260, tap=True)
        prev = view(top)
        for i in (1, 2):                                  # two fast b/w frames with ghosting
            pos = top + (target - top) * i // 2
            frame = Image.blend(dither(view(pos)), prev, 0.18)
            add(frame, 110)
        if glide == 3:                                    # the occasional clean full flash
            add(Image.new("L", (W, H), 0), 140)
            add(Image.new("L", (W, H), 255), 90)
        top = target
        add(view(top), 1500)
    add(view(top), 1800)

    pal = [f.convert("P", palette=Image.ADAPTIVE, colors=32) for f in frames]
    out = os.path.join(os.path.dirname(__file__), "demo.gif")
    pal[0].save(out, save_all=True, append_images=pal[1:], duration=durations, loop=0, optimize=True)
    print(out, len(frames), "frames", os.path.getsize(out) // 1024, "KB")


if __name__ == "__main__":
    main()
