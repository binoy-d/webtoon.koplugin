"""Render docs/library.png: the on-device library flow, drawn as four e-reader screens.

Series names are made up (the robot from the demo GIF), so the repo ships no third-party art.

    python docs/make_library_png.py
"""
import os

from PIL import Image, ImageDraw, ImageFont

W, H = 300, 400            # simulated screen
BEZEL, CHIN, GAP = 18, 40, 26
CAPTION = 54


def font(size, bold=False):
    names = (["/System/Library/Fonts/Supplemental/Arial Bold.ttf",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"] if bold else
             ["/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"])
    for f in names:
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default(size=size)


def titlebar(d, title):
    d.text((W // 2, 22), title, font=font(16, True), fill=0, anchor="mm")
    d.line([(10, 42), (W - 10, 42)], fill=0, width=2)


def rows(d, items, top=48, h=34):
    for i, (left, right) in enumerate(items):
        y = top + i * h
        d.text((14, y + h // 2), left, font=font(13), fill=0, anchor="lm")
        if right:
            d.text((W - 14, y + h // 2), right, font=font(12), fill=90, anchor="rm")
        d.line([(10, y + h), (W - 10, y + h)], fill=200, width=1)


def dialog(im, title, body, buttons, top=110, height=170, field=None):
    d = ImageDraw.Draw(im)
    x0, x1 = 20, W - 20
    d.rounded_rectangle((x0, top, x1, top + height), radius=8, fill=255, outline=0, width=2)
    y = top + 22
    if title:
        d.text((W // 2, y), title, font=font(15, True), fill=0, anchor="mm")
        y += 26
    for ln in body:
        d.text((W // 2, y), ln, font=font(13), fill=0, anchor="mm")
        y += 20
    if field:
        d.rectangle((x0 + 16, y - 6, x1 - 16, y + 22), outline=0, width=2)
        d.text((x0 + 24, y + 8), field, font=font(14), fill=0, anchor="lm")
        d.line([(x0 + 24 + d.textlength(field, font=font(14)) + 2, y - 1), (x0 + 24 + d.textlength(field, font=font(14)) + 2, y + 17)], fill=0, width=2)
    by = top + height - 40
    d.line([(x0, by), (x1, by)], fill=0, width=1)
    bw = (x1 - x0) / len(buttons)
    for i, b in enumerate(buttons):
        cx = x0 + bw * (i + 0.5)
        d.text((cx, by + 20), b, font=font(13, i == len(buttons) - 1), fill=0, anchor="mm")
        if i:
            d.line([(x0 + bw * i, by), (x0 + bw * i, top + height)], fill=0, width=1)


def keyboard(d):
    top = H - 120
    d.rectangle((0, top, W, H), fill=230)
    for r, keys in enumerate(("qwertyuiop", "asdfghjkl", "zxcvbnm")):
        kw = 26
        x = (W - len(keys) * (kw + 3)) // 2
        for k in keys:
            y = top + 8 + r * 36
            d.rounded_rectangle((x, y, x + kw, y + 30), radius=4, fill=255, outline=150)
            d.text((x + kw // 2, y + 15), k, font=font(13), fill=0, anchor="mm")
            x += kw + 3


def screen_search():
    im = Image.new("L", (W, H), 255)
    d = ImageDraw.Draw(im)
    titlebar(d, "Webtoons")
    rows(d, [("Search webtoons…", ""), ("Check for new episodes", ""), ("Robot Diaries", "12 downloaded")])
    dialog(im, "Search webtoons", [], ["Cancel", "Search"], top=70, height=130, field="robot")
    keyboard(ImageDraw.Draw(im))
    return im


def screen_results():
    im = Image.new("L", (W, H), 255)
    d = ImageDraw.Draw(im)
    titlebar(d, "Results for “robot”")
    rows(d, [("Robot Diaries", "B. Bolt"), ("Rust & Romance", "Gearhead"),
             ("Small Robot, Big City", "M. Ohm · Canvas"), ("The Last Android", "Volta"),
             ("Robo Chef", "Sparks · Canvas"), ("Mecha Homeroom", "K. Rivet"),
             ("Circuit Hearts", "Diode · Canvas"), ("Steel Garden", "Anode")])
    return im


def screen_series():
    im = Image.new("L", (W, H), 255)
    d = ImageDraw.Draw(im)
    titlebar(d, "Robot Diaries")
    rows(d, [("↓  Download next 5 episodes", ""), ("↓  Download a range…", ""),
             ("Ep. 14 - Low Battery", "…"), ("Ep. 13 - The Upgrade", "…"),
             ("Ep. 12 - Rainy Day", "↓"), ("Ep. 11 - New Friend", "42%"),
             ("Ep. 10 - Lost Bolt", "✓"), ("Ep. 9 - Night Shift", "✓"), ("Ep. 8 - Spare Parts", "✓"),
             ("Ep. 7 - First Day", "✓")])
    return im


def screen_more():
    im = Image.new("L", (W, H), 255)
    d = ImageDraw.Draw(im)
    # end of an episode: the last panel of the strip
    d.rectangle((16, 30, W - 16, 360), fill=215, outline=0, width=3)
    d.ellipse((115, 100, 185, 170), fill=245, outline=0, width=3)
    d.text((W // 2, 80), "TO BE CONTINUED", font=font(16, True), fill=0, anchor="mm")
    dialog(im, None, ["That was the last downloaded", "episode.", "", "Download the next 5", "in the background?"],
           ["Not now", "Download next 5"], top=190, height=180)
    return im


def main():
    screens = [(screen_search(), "1. Search"), (screen_results(), "2. Pick a series"),
               (screen_series(), "3. Download episodes"), (screen_more(), "4. Ran out? One tap")]
    fw, fh = W + 2 * BEZEL, H + BEZEL + CHIN
    out = Image.new("RGB", (len(screens) * fw + (len(screens) - 1) * GAP, fh + CAPTION), "white")
    d = ImageDraw.Draw(out)
    for i, (scr, cap) in enumerate(screens):
        x = i * (fw + GAP)
        d.rounded_rectangle((x, 0, x + fw - 1, fh - 1), radius=22, fill=(38, 38, 40))
        out.paste(scr.convert("RGB"), (x + BEZEL, BEZEL))
        d.text((x + fw // 2, fh + CAPTION // 2), cap, font=font(20, True), fill=(30, 30, 30), anchor="mm")
    path = os.path.join(os.path.dirname(__file__), "library.png")
    out.save(path, optimize=True)
    print("wrote", path)


if __name__ == "__main__":
    main()
