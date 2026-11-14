"""kowebtoon: webtoons -> e-ink friendly CBZs for KOReader (pairs with webtoon.koplugin).

  kowebtoon config --device kindle-pw5 --to /Volumes/Kindle/books/Webtoons
  kowebtoon get <series URL> --episodes 1-10        # grab + deliver
  kowebtoon follow <series URL>                     # remember a series
  kowebtoon sync                                    # grab new episodes of everything followed
"""
import argparse
import json
import os
import re
import sys

from . import __version__, deliver, devices, render, webtoons

CONFIG = os.path.expanduser(os.environ.get("KOWEBTOON_CONFIG", "~/.config/kowebtoon/config.json"))
DEFAULT_OUT = os.path.expanduser("~/.local/share/kowebtoon")


def load_config():
    try:
        with open(CONFIG) as f:
            return json.load(f)
    except FileNotFoundError:
        return {"series": {}}


def save_config(cfg):
    os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
    with open(CONFIG, "w") as f:
        json.dump(cfg, f, indent=2)


def safe(s):
    return re.sub(r'[\\/:*?"<>|]+', "", s).strip()


def parse_range(spec, available):
    if not spec:
        return list(available)
    if spec == "latest":
        return list(available)[-1:]
    want = set()
    for part in spec.split(","):
        a, _, b = part.partition("-")
        want.update(range(int(a), int(b or a) + 1))
    return [n for n in available if n in want]


def grab(url, episodes, cfg, args):
    width, height = devices.resolve(args.device or cfg.get("device"), args.width, args.height)
    fmt = args.format or cfg.get("format", "scroll")
    out_root = os.path.expanduser(args.out or cfg.get("out", DEFAULT_OUT))
    series, eps = webtoons.list_episodes(url)
    series_dir = safe(series)
    sdir = os.path.join(out_root, series_dir)
    os.makedirs(sdir, exist_ok=True)
    chosen = set(parse_range(episodes, [n for n, _, _ in eps]))
    print(f"{series}: {len(eps)} episodes, {len(chosen)} selected ({fmt}, {width}x{height})")
    made = []
    for n, subj, viewer in eps:
        if n not in chosen:
            continue
        name = f"{n:03d} - {safe(subj)}.cbz"
        path = os.path.join(sdir, name)
        if os.path.exists(path) and not args.force:
            continue
        urls = webtoons.episode_image_urls(viewer)
        if not urls:
            print(f"  ep {n}: locked or not free, skipped")
            continue
        parts = render.load_strips([webtoons.fetch(u) for u in urls], width)
        ep_title = re.sub(r"^(Ep\.|Episode)\s*\d+\s*[-:–]\s*", "", subj)
        cover = None if args.no_cover else render.make_cover(parts, series, n, ep_title, width, height)
        if fmt == "scroll":
            strips, gaps = render.make_scroll_cbz(parts, path, f"{series} {subj}", cover)
            print(f"  ep {n}: {strips} strips, {gaps} panel gaps -> {name}")
        else:
            pages = render.make_pages_cbz(parts, path, f"{series} {subj}", width, height, cover)
            print(f"  ep {n}: {pages} pages -> {name}")
        made.append(path)
    dest = args.to or cfg.get("to")
    if dest and made:
        deliver.deliver(made, dest, series_dir)
        print(f"  delivered {len(made)} to {dest}/{series_dir}")
    elif made and not dest:
        print(f"  saved in {sdir} (set a destination with: kowebtoon config --to ...)")
    return series, max([n for n, _, _ in eps if n in chosen] or [0])


def main(argv=None):
    ap = argparse.ArgumentParser(prog="kowebtoon", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", action="version", version=__version__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("--device", help="screen preset (see: kowebtoon devices)")
        p.add_argument("--width", type=int); p.add_argument("--height", type=int)
        p.add_argument("--format", choices=["scroll", "pages"],
                       help="scroll (default, needs webtoon.koplugin) or pages (any reader)")
        p.add_argument("--to", help="destination: a folder on the mounted e-reader, or ssh://[user@]host[:port]/path")
        p.add_argument("--out", help=f"local library folder (default {DEFAULT_OUT})")
        p.add_argument("--no-cover", action="store_true", help="don't add a title cover page")
        p.add_argument("--force", action="store_true", help="rebuild episodes that already exist")

    g = sub.add_parser("get", help="grab episodes of a series"); common(g)
    g.add_argument("url"); g.add_argument("--episodes", help="e.g. 1-10, 3,5,8 or latest (default: all)")
    f = sub.add_parser("follow", help="remember a series for `sync`")
    f.add_argument("url"); f.add_argument("--from", dest="start", type=int, default=1,
                                          help="first episode to sync (default 1)")
    sub.add_parser("unfollow", help="forget a series").add_argument("name")
    s = sub.add_parser("sync", help="grab new episodes of every followed series"); common(s)
    sub.add_parser("list", help="show followed series")
    sub.add_parser("devices", help="list screen presets")
    c = sub.add_parser("config", help="set defaults")
    c.add_argument("--device"); c.add_argument("--to"); c.add_argument("--out")
    c.add_argument("--format", choices=["scroll", "pages"])

    a = ap.parse_args(argv)
    cfg = load_config()

    if a.cmd == "devices":
        for k, (w, h) in sorted(devices.DEVICES.items()):
            print(f"{k:16} {w}x{h}")
    elif a.cmd == "config":
        for k in ("device", "to", "out", "format"):
            if getattr(a, k):
                cfg[k] = getattr(a, k)
        save_config(cfg)
        print(json.dumps({k: v for k, v in cfg.items() if k != "series"}, indent=2))
    elif a.cmd == "get":
        grab(a.url, a.episodes, cfg, a)
    elif a.cmd == "follow":
        series, eps = webtoons.list_episodes(a.url)
        cfg.setdefault("series", {})[series] = {"url": a.url, "next": a.start}
        save_config(cfg)
        print(f"following {series} ({len(eps)} episodes; syncing from ep {a.start})")
    elif a.cmd == "unfollow":
        if cfg.get("series", {}).pop(a.name, None) is None:
            sys.exit(f"not following {a.name!r}")
        save_config(cfg)
    elif a.cmd == "list":
        for name, s in cfg.get("series", {}).items():
            print(f"{name}: next ep {s['next']}  {s['url']}")
    elif a.cmd == "sync":
        for name, s in list(cfg.get("series", {}).items()):
            _, last = grab(s["url"], f"{s['next']}-99999", cfg, a)
            if last >= s["next"]:
                s["next"] = last + 1
                save_config(cfg)


if __name__ == "__main__":
    main()
