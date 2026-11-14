"""Synthetic-image tests for the panel finder and page packer (no network, no real comics)."""
import io
import json
import os
import tempfile
import unittest
import zipfile

from PIL import Image, ImageDraw

from kowebtoon import cli, render


def strip_with_panels(width=600, panels=((100, 400), (600, 900), (1100, 1500)), bubble=None):
    """White strip with dark rectangles as panels; optional bubble outline (y0, y1)."""
    h = panels[-1][1] + 120
    im = Image.new("L", (width, h), 255)
    d = ImageDraw.Draw(im)
    for y0, y1 in panels:
        d.rectangle((40, y0, width - 40, y1), fill=90)
    if bubble:
        d.ellipse((width - 260, bubble[0], width - 60, bubble[1]), outline=0, width=1, fill=255)
    return im


class GutterTests(unittest.TestCase):
    def test_finds_gaps_between_panels(self):
        im = strip_with_panels()
        spread, _ = render.row_profile(im)
        gutters = render.find_gutters(spread, im.width)
        for g in gutters:
            self.assertFalse(any(y0 <= g <= y1 for y0, y1 in ((100, 400), (600, 900), (1100, 1500))))
        self.assertTrue(any(400 < g < 600 for g in gutters))
        self.assertTrue(any(900 < g < 1100 for g in gutters))

    def test_thin_bubble_outline_blocks_a_cut(self):
        # a speech bubble straddles the 400..600 gap: no gutter may fall inside the bubble
        im = strip_with_panels(bubble=(360, 560))
        spread, _ = render.row_profile(im)
        for g in render.find_gutters(spread, im.width):
            self.assertFalse(360 <= g <= 560, f"cut at {g} runs through the bubble")


class FormatTests(unittest.TestCase):
    def test_scroll_cbz_embeds_map_and_cover(self):
        parts = [strip_with_panels().crop((0, 0, 600, 800)), strip_with_panels().crop((0, 800, 600, 1620))]
        cover = render.make_cover(parts, "Series", 7, "An episode", 600, 800)
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "ep.cbz")
            strips, gaps = render.make_scroll_cbz(parts, path, "Series 7", cover)
            z = zipfile.ZipFile(path)
            meta = json.loads(z.read("kowebtoon.json"))
            self.assertEqual(strips, 2)
            self.assertEqual(meta["first_page"], 2)
            self.assertEqual(len(meta["gaps"]), gaps)
            self.assertTrue(all(g[0] >= 2 for g in meta["gaps"]), "gap pages must count the cover")
            self.assertEqual(Image.open(io.BytesIO(z.read("001.jpg"))).size, (600, 800))

    def test_tall_panel_kept_whole_on_one_page(self):
        im = strip_with_panels(panels=((100, 1500),))       # one panel ~1.75x the page height
        with tempfile.TemporaryDirectory() as d:
            n = render.make_pages_cbz([im], os.path.join(d, "ep.cbz"), "t", 600, 800)
        self.assertEqual(n, 1)

    def test_eink_levels(self):
        im = render.to_eink(Image.linear_gradient("L"))
        self.assertLessEqual(len(set(im.getdata())), 16)


class CliTests(unittest.TestCase):
    def test_parse_range(self):
        self.assertEqual(cli.parse_range("2-4,7", range(1, 10)), [2, 3, 4, 7])
        self.assertEqual(cli.parse_range("latest", [1, 2, 3]), [3])
        self.assertEqual(cli.parse_range(None, [1, 2]), [1, 2])


if __name__ == "__main__":
    unittest.main()
