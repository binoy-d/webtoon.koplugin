"""Turn an episode's image strips into a CBZ tuned for e-ink.

"scroll" (default): the strips untouched except resized to the screen width and reduced to the
16 grey levels e-ink panels show, plus kowebtoon.json inside the CBZ: where every blank gap
between panels is. webtoon.koplugin snaps taps to those gaps.

"pages": pre-cut screen-shaped pages for readers without the plugin. Cuts only in gaps between
panels; a panel up to 2x the screen height gets its own shrunk-to-fit page.
"""
import html
import io
import json
import os
import zipfile

import numpy as np
from PIL import Image, ImageOps

FORMAT_VERSION = 1
GUTTER_SPREAD = 6       # a row counts as blank if every pixel is within this many grey levels
MAX_SHRINK = 2.0        # pages format: a single panel up to this x page height stays whole


def load_strips(blobs, width, margin=0.0):
    """Decode, greyscale and resize every strip to the screen width (no on-device scaling).

    margin: blank space left and right of the art, as a fraction of the width per side.
    """
    art_w = max(1, round(width * (1 - 2 * margin)))
    parts = []
    for b in blobs:
        im = ImageOps.grayscale(Image.open(io.BytesIO(b)).convert("RGB"))
        if im.width != art_w:
            im = im.resize((art_w, max(1, round(im.height * art_w / im.width))), Image.LANCZOS)
        if art_w != width:
            page = Image.new("L", (width, im.height), 255)
            page.paste(im, ((width - art_w) // 2, 0))
            im = page
        parts.append(im)
    return parts


def to_eink(im):
    """Snap to the 16 grey levels e-ink panels actually show: crisper fast refreshes, smaller files."""
    return im.point(lambda v: min(255, round(v / 17) * 17))


def row_profile(img):
    """Per row, over EVERY pixel: (spread, mean). Every pixel matters: a speech bubble's 1px
    outline must stop a row from counting as blank, or a cut lands between lines of dialogue."""
    a = np.asarray(img, dtype=np.int16)
    return (a.max(axis=1) - a.min(axis=1)), a.mean(axis=1).round().astype(int)


def find_gutters(spread, width):
    """Centres of blank row runs tall enough to be a gap between panels."""
    min_run = max(8, width // 60)
    blank = spread <= GUTTER_SPREAD
    gutters, y, h = [], 0, len(spread)
    while y < h:
        if blank[y]:
            s = y
            while y < h and blank[y]:
                y += 1
            if y - s >= min_run:
                gutters.append((s + y) // 2)
        y += 1
    return gutters


def stack(parts):
    out = Image.new("L", (parts[0].width, sum(p.height for p in parts)), 255)
    y = 0
    for p in parts:
        out.paste(p, (0, y)); y += p.height
    return out


def _font(size, bold=False):
    from PIL import ImageFont
    custom = os.environ.get("KOWEBTOON_FONT_BOLD" if bold else "KOWEBTOON_FONT")
    for f in filter(None, [custom,
                           "/System/Library/Fonts/Supplemental/Georgia Bold.ttf" if bold else
                           "/System/Library/Fonts/Supplemental/Georgia.ttf",
                           "/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf" if bold else
                           "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf"]):
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default(size=size)


def _wrap(draw, text, font, max_w, max_lines):
    words, lines, line = text.split(), [], ""
    for w in words:
        trial = f"{line} {w}".strip()
        if draw.textlength(trial, font=font) <= max_w or not line:
            line = trial
        else:
            lines.append(line); line = w
    if line:
        lines.append(line)
    if len(lines) > max_lines:
        lines = lines[:max_lines]
        while lines[-1] and draw.textlength(lines[-1] + "…", font=font) > max_w:
            lines[-1] = lines[-1][:-1]
        lines[-1] = lines[-1].rstrip() + "…"
    return lines


def make_cover(parts, series, ep_no, ep_title, screen_w, screen_h):
    """A screen-sized cover: the episode's busiest scene on top, title band below."""
    from PIL import ImageDraw
    strip = stack(parts)
    w = strip.width
    h = round(w * screen_h / screen_w)
    art_h = round(h * 0.64)
    # cover art = one WHOLE panel (span between two gaps, so no bubble is cut): the most detailed
    # reasonably big one, skipping the first 10% (usually a title card), fitted into the art box
    spread, _ = row_profile(strip)
    bounds = [0] + find_gutters(spread, w) + [strip.height]
    a = np.asarray(strip, dtype=np.float32)
    best, best_span = -1.0, (0, min(strip.height, art_h))
    for s, e in zip(bounds, bounds[1:]):
        if e - s < art_h * 0.3 or s < strip.height * 0.1:
            continue
        score = float(a[s:e].std()) * min(1.0, (e - s) / art_h)
        if score > best:
            best, best_span = score, (s, e)
    panel = strip.crop((0, best_span[0], w, best_span[1]))
    px = np.asarray(panel, dtype=np.int16)     # trim blank margins on all sides so the panel fills the box
    busy_x = np.where((px.max(axis=0) - px.min(axis=0)) > GUTTER_SPREAD)[0]
    busy_y = np.where((px.max(axis=1) - px.min(axis=1)) > GUTTER_SPREAD)[0]
    if len(busy_x) and len(busy_y):
        panel = panel.crop((int(busy_x[0]), int(busy_y[0]), int(busy_x[-1]) + 1, int(busy_y[-1]) + 1))
    pad = round(w * 0.04)
    box_w, box_h = w - 2 * pad, art_h - 2 * pad
    scale = min(box_w / panel.width, box_h / panel.height)
    panel = panel.resize((max(1, round(panel.width * scale)), max(1, round(panel.height * scale))), Image.LANCZOS)
    cover = Image.new("L", (w, h), 255)
    cover.paste(panel, ((w - panel.width) // 2, pad + (box_h - panel.height) // 2))
    d = ImageDraw.Draw(cover)
    d.rectangle((0, art_h, w, h), fill=255)
    d.line((0, art_h, w, art_h), fill=0, width=max(2, w // 300))
    m = round(w * 0.07)
    y = art_h + round(h * 0.035)
    small, big, mid = _font(round(w * 0.035)), _font(round(w * 0.085), bold=True), _font(round(w * 0.05))
    d.text((m, y), f"EPISODE {ep_no}", font=small, fill=90)
    y += round(w * 0.06)
    for line in _wrap(d, series, big, w - 2 * m, 2):
        d.text((m, y), line, font=big, fill=0)
        y += round(w * 0.1)
    y += round(w * 0.015)
    for line in _wrap(d, ep_title, mid, w - 2 * m, 2):
        d.text((m, y), line, font=mid, fill=60)
        y += round(w * 0.065)
    return to_eink(cover)


def _zip_jpegs(path, images, title, extra=None):
    tmp = path + ".part"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_STORED) as z:
        for i, im in enumerate(images, 1):
            buf = io.BytesIO()
            im.save(buf, "JPEG", quality=85, optimize=True)
            z.writestr(f"{i:03d}.jpg", buf.getvalue())
        z.writestr("ComicInfo.xml", "<?xml version='1.0'?><ComicInfo>"
                                    f"<Title>{html.escape(title, quote=False)}</Title></ComicInfo>")
        for name, data in (extra or {}).items():
            z.writestr(name, data)
    os.replace(tmp, path)


def make_scroll_cbz(parts, path, title, cover=None):
    """[cover] + strips as pages + kowebtoon.json panel map. Returns (strips, gaps).

    Page numbers in "gaps" count the cover, so they match what KOReader sees.
    """
    parts = [to_eink(p) for p in parts]
    spread, _ = row_profile(stack(parts))
    offset = 1 if cover is not None else 0
    tops, acc = [], 0
    for p in parts:
        tops.append(acc); acc += p.height
    gaps, pi = [], 0
    for g in find_gutters(spread, parts[0].width):
        while pi + 1 < len(parts) and tops[pi + 1] <= g:
            pi += 1
        gaps.append([pi + 1 + offset, round((g - tops[pi]) / parts[pi].height, 5)])
    meta = {"kowebtoon": FORMAT_VERSION, "title": title, "width": parts[0].width,
            "first_page": 1 + offset, "gaps": gaps}
    pages = ([cover] if cover is not None else []) + parts
    _zip_jpegs(path, pages, title, {"kowebtoon.json": json.dumps(meta, separators=(",", ":"))})
    return len(parts), len(gaps)


def _pack(spread, h, target):
    gutters = find_gutters(spread, 0)
    overlap = int(target * 0.08)
    bounds = [0] + [g for g in gutters if 0 < g < h] + [h]
    spans, start, end = [], 0, 0
    for b in bounds[1:]:
        if b - start <= target:
            end = b
            continue
        if end > start:
            spans.append((start, end)); start = end
            if b - start <= target:
                end = b
                continue
        if b - start <= target * MAX_SHRINK:
            spans.append((start, b))
        else:
            top = start
            while b - top > target:
                window = range(top + int(target * 0.6), top + target)
                cut = min(window, key=lambda r: (spread[r], -r))
                spans.append((top, cut)); top = max(top + 1, cut - overlap)
            spans.append((top, b))
        start = end = b
    if end > start:
        spans.append((start, end))
    return spans


def _fit(page, target, top_color, bottom_color):
    w = page.width
    if page.height > target:
        nw = max(1, round(w * target / page.height))
        cols = np.asarray(page, dtype=np.int16)
        out = Image.new("L", (w, target), int(cols[:, -1].mean()))
        out.paste(int(cols[:, 0].mean()), (0, 0, (w - nw) // 2, target))
        out.paste(page.resize((nw, target), Image.LANCZOS), ((w - nw) // 2, 0))
        return out
    if page.height == target:
        return page
    extra = target - page.height
    out = Image.new("L", (w, target), int(bottom_color))
    if top_color != bottom_color:
        out.paste(int(top_color), (0, 0, w, extra // 2))
    out.paste(page, (0, extra // 2))
    return out


def make_pages_cbz(parts, path, title, screen_w, screen_h, cover=None):
    """[cover] + pre-cut screen-shaped pages. Returns page count (without cover)."""
    strip = stack(parts)
    spread, mean = row_profile(strip)
    target = round(strip.width * screen_h / screen_w)
    pages = [cover] if cover is not None else []
    for a, b in _pack(spread, strip.height, target):
        page = strip.crop((0, a, strip.width, b))
        lo, hi = page.getextrema()
        if hi - lo < 10:                      # solid spacer: nothing to read
            continue
        pages.append(to_eink(_fit(page, target, mean[a], mean[b - 1])))
    _zip_jpegs(path, pages, title)
    return len(pages) - (1 if cover is not None else 0)
