# koreader-webtoon

Read webtoons on an e-ink reader the way they're meant to be read: one long vertical strip,
not chopped into pages that slice through panels and speech bubbles.

Two parts that work together:

- **`webtoon.koplugin`**: a [KOReader](https://koreader.rocks) plugin. Each tap glides the strip
  up so the next panel lands at the top of the screen, pre-renders what's below, and opens the
  next episode when you reach the end.
- **`kowebtoon`**: a command-line converter. It turns webtoons.com episodes into CBZs made for
  e-ink (screen-width, 16 grey levels, a title cover) with a map of where every gap between
  panels is, and copies them to your reader.

## How it reads

- **Tap forward:** a short glide (2 fast frames, then one clean refresh) to the last gap between
  panels that was on screen. You never start reading mid-panel.
- **Tap back:** the same, upwards.
- **Panels taller than the screen** scroll about 85% at a time, with a little overlap.
- **Swipe** to scroll freely.
- **End of an episode:** "Next: Ep. 4" and it opens.
- **First open** switches the episode to continuous view, page-width zoom, no page gaps, and
  skips the cover. Your books are untouched.

E-ink can't do smooth 60 fps scrolling. The glide is designed around that: a couple of quick
black-and-white frames for motion, then one proper greyscale refresh, plus a full flash every
20 taps to clear ghosting. Everything is adjustable in **Settings → Webtoon scroll**.

## Install

### 1. The plugin

Copy `webtoon.koplugin/` into KOReader's `plugins/` folder and restart KOReader:

| Device | Plugins folder |
| --- | --- |
| Kindle | `/mnt/us/koreader/plugins/` (USB: `koreader/plugins/`) |
| Kobo | `.adds/koreader/plugins/` |
| PocketBook | `applications/koreader/plugins/` |
| Android | `koreader/plugins/` in internal storage |

### 2. The converter

Python 3.9 or newer:

```bash
pipx install git+https://github.com/binoy-d/koreader-webtoon
# or: pip install git+https://github.com/binoy-d/koreader-webtoon
```

## Use

Tell it your device and where episodes should go (once):

```bash
kowebtoon devices                                   # list screen presets
kowebtoon config --device kindle-pw5 --to /Volumes/Kindle/koreader-books/Webtoons
```

`--to` is a folder on the plugged-in reader, or `ssh://user@host:port/path` if you run an
SSH server on it (for example KOReader's built-in one). Repeat `--to` to deliver the same files
to several places, e.g. your reader *and* the library folder of a book server that syncs with
KOReader (BookOrbit, Calibre-Web, ...). Identical files mean reading progress can sync between
them. If one destination is unreachable (reader asleep), the others still get the episodes;
send them again later with `--resend`.

Grab episodes:

```bash
kowebtoon get "https://www.webtoons.com/en/<genre>/<series>/list?title_no=<id>" --episodes 1-10
```

Follow series and pick up new episodes whenever you like (or from cron):

```bash
kowebtoon follow "https://www.webtoons.com/en/<genre>/<series>/list?title_no=<id>"
kowebtoon sync
```

Each episode becomes `<Series>/<NNN> - <Episode title>.cbz`, with a cover showing the series,
episode number and title, so it looks right in KOReader's cover browser.

No plugin? Use `--format pages` for pre-cut, screen-shaped pages that work in any reader. Cuts
only happen in gaps between panels, and a panel up to twice the screen height gets its own page.

## How the converter finds panels

A row of pixels counts as a gap only if *every* pixel in it is blank. Checking every pixel
matters: a speech bubble's one-pixel outline is enough to stop a cut, so no line of dialogue
gets split. The gaps are stored in `kowebtoon.json` inside the CBZ (page number + position on
the page), so they travel with the file however your KOReader stores its sidecars.

## Other webtoon CBZs

Enable **Settings → Webtoon scroll → Glide on any tall comic** to get the glide (in fixed
steps, without panel snapping) for webtoon CBZs from other tools.

## Responsible use

kowebtoon only fetches episodes that webtoons.com shows for free, for reading on your own
device. Support the creators: read new episodes on WEBTOON too, and don't redistribute files.

## Development

```bash
pip install -e .
python -m unittest discover -s tests -v
```

The tests use synthetic images only. Plugin settings live in KOReader's `settings.reader.lua`
under `webtoon`.

## License

MIT
