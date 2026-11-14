"""Copy finished episodes to a reader or library: a folder, or ssh://[user@]host[:port]/path.

Add ?layout=folders to a destination to give every episode its own folder
(<series>/<episode>/<episode>.cbz). Library servers such as BookOrbit treat files sharing a
folder as formats of one book, so they need this to list each episode separately.
"""
import os
import shlex
import shutil
import subprocess
import tempfile
from urllib.parse import parse_qs, urlparse


def _split(dest):
    """'path?layout=folders' -> ('path', 'folders')."""
    base, _, query = dest.partition("?")
    return base, (parse_qs(query).get("layout") or ["flat"])[0]


def _staged(files, layout):
    """Yield (dir to tar from, member names) arranged in the requested layout."""
    if layout != "folders":
        return os.path.dirname(files[0]), [os.path.basename(f) for f in files], None
    tmp = tempfile.mkdtemp(prefix="kowebtoon-")
    names = []
    for f in files:
        stem = os.path.splitext(os.path.basename(f))[0]
        os.makedirs(os.path.join(tmp, stem), exist_ok=True)
        os.link(f, os.path.join(tmp, stem, os.path.basename(f))) if hasattr(os, "link") else \
            shutil.copy2(f, os.path.join(tmp, stem))
        names.append(stem)
    return tmp, names, tmp


def deliver(files, dest, series_dir):
    """Put `files` under <dest>/<series_dir>/ in the destination's layout (creating folders)."""
    if not files:
        return
    dest, layout = _split(dest)
    src_dir, names, cleanup = _staged(files, layout)
    try:
        if dest.startswith("ssh://"):
            u = urlparse(dest)
            remote = f"{u.path.rstrip('/')}/{series_dir}"
            ssh = ["ssh", "-o", "ConnectTimeout=10"] + (["-p", str(u.port)] if u.port else [])
            host = f"{u.username}@{u.hostname}" if u.username else u.hostname
            tar = subprocess.Popen(["tar", "-C", src_dir, "-cf", "-"] + names, stdout=subprocess.PIPE)
            cmd = f"mkdir -p {shlex.quote(remote)} && tar -C {shlex.quote(remote)} -xf -"
            subprocess.run(ssh + [host, cmd], stdin=tar.stdout, check=True)
            tar.wait()
        else:
            root = os.path.expanduser(dest)
            if not os.path.isdir(root):
                raise SystemExit(f"destination not found: {dest} (is the e-reader plugged in?)")
            target = os.path.join(root, series_dir)
            os.makedirs(target, exist_ok=True)
            for n in names:
                src = os.path.join(src_dir, n)
                if os.path.realpath(src) == os.path.realpath(os.path.join(target, n)):
                    continue
                if os.path.isdir(src):
                    shutil.copytree(src, os.path.join(target, n), dirs_exist_ok=True)
                else:
                    shutil.copy2(src, target)
    finally:
        if cleanup:
            shutil.rmtree(cleanup, ignore_errors=True)
