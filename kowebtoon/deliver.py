"""Copy finished episodes to the e-reader: a mounted folder, or ssh://[user@]host[:port]/path."""
import os
import shlex
import shutil
import subprocess
from urllib.parse import urlparse


def deliver(files, dest, series_dir):
    """Put `files` into <dest>/<series_dir>/ (creating it)."""
    if not files:
        return
    if dest.startswith("ssh://"):
        u = urlparse(dest)
        remote = f"{u.path.rstrip('/')}/{series_dir}"
        ssh = ["ssh", "-o", "ConnectTimeout=10"] + (["-p", str(u.port)] if u.port else [])
        host = f"{u.username}@{u.hostname}" if u.username else u.hostname
        tar = subprocess.Popen(["tar", "-C", os.path.dirname(files[0]), "-cf", "-"]
                               + [os.path.basename(f) for f in files], stdout=subprocess.PIPE)
        cmd = f"mkdir -p {shlex.quote(remote)} && tar -C {shlex.quote(remote)} -xf -"
        subprocess.run(ssh + [host, cmd], stdin=tar.stdout, check=True)
        tar.wait()
    else:
        target = os.path.join(os.path.expanduser(dest), series_dir)
        if not os.path.isdir(os.path.expanduser(dest)):
            raise SystemExit(f"destination not found: {dest} (is the e-reader plugged in?)")
        os.makedirs(target, exist_ok=True)
        for f in files:
            if os.path.realpath(os.path.dirname(f)) != os.path.realpath(target):
                shutil.copy2(f, target)
