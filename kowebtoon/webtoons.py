"""webtoons.com: list a series' episodes and an episode's image strips (free episodes only)."""
import html
import re
import time

import requests

UA = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 "
                    "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"}
IMG_HEADERS = {**UA, "Referer": "https://www.webtoons.com/"}


def get(url, headers=UA, tries=4):
    for attempt in range(tries):
        try:
            r = requests.get(url, headers=headers, timeout=30)
            r.raise_for_status()
            return r
        except requests.RequestException:
            if attempt == tries - 1:
                raise
            time.sleep(2 * (attempt + 1))


def is_series_url(url):
    return "webtoons.com" in url and "title_no=" in url


def list_episodes(list_url):
    """Return (series title, [(episode_no, title, viewer_url)] oldest first)."""
    m = re.search(r"title_no=(\d+)", list_url)
    if not m:
        raise SystemExit(f"not a webtoons.com series URL (needs title_no=): {list_url}")
    base = re.sub(r"&page=\d+", "", list_url)
    eps, page, series = {}, 1, None
    while True:
        text = get(f"{base}&page={page}").text
        if series is None:
            t = re.search(r'<meta property="og:title" content="([^"]+)"', text)
            series = html.unescape(t.group(1)) if t else f"webtoon-{m.group(1)}"
        found = re.findall(r'<li class="_episodeItem[^"]*"[^>]*data-episode-no="(\d+)".*?href="([^"]+)".*?'
                           r'<span class="subj"><span>(.*?)</span>', text, re.S)
        new = [(int(n), html.unescape(s).strip(), html.unescape(h)) for n, h, s in found if int(n) not in eps]
        if not new:
            break
        for n, s, h in new:
            eps[n] = (n, s, h)
        page += 1
    return series, [eps[k] for k in sorted(eps)]


def episode_image_urls(viewer_url):
    """Image strip URLs for one episode; empty if the episode is locked/paid."""
    return re.findall(r'<img[^>]+class="_images"[^>]+data-url="([^"]+)"', get(viewer_url).text)


def fetch(url):
    return get(url, headers=IMG_HEADERS).content
