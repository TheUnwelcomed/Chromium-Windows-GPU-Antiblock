#!/usr/bin/env python3
"""chromium-latest-linux, done again: Chromium on Linux that draws on the graphics card. Python 3.8+, nothing to install.

    ./update.sh [stable|beta|dev|canary|153|153.0.8010.52]  fetch Chrome for Testing (default: stable)
    ./run.sh [URL ...] [--switch ...]                                 start it with flags.txt and what this machine needs
    ./check.sh [keep] [--switch ...]                                  ask it what it does with the card -> reports/
    python3 -I antiblock.py reset | status

The same as the Windows scripts one folder up (antiblock.ps1), for Linux (RHEL 9 here): builds/, profile/ and
reports/ live beside this file, and nothing of an installed Chrome or Chromium is touched. Chrome for Testing and not
a raw Chromium snapshot, which chromium-latest-linux fetched: a snapshot is built without the proprietary codecs
(build/config/features.gni) - no H.264, no AAC, no HEVC - and the IPTV channels need them. (EPEL's Chromium on
RHEL 9 is built without them too.)
"""
import base64
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOP = os.path.dirname(HERE)
BUILDS = os.path.join(HERE, "builds")
PROFILE = os.path.join(HERE, "profile")
CHECK_PROFILE = os.path.join(HERE, "profile-check")
REPORTS = os.path.join(HERE, "reports")
FLAGS = os.path.join(HERE, "flags.txt")
CURRENT = os.path.join(BUILDS, "current.txt")
CFT = "https://googlechromelabs.github.io/chrome-for-testing/"
UA = {"User-Agent": "Chromium-Windows-GPU-Antiblock (linux)"}
KEEP = 2  # the build in use and one before it


def get(url, timeout=60):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r:
        return r.read()


def get_json(url):
    return json.loads(get(url).decode("utf-8"))


def object_info(bucket, obj):
    """Google's own record of a file in its storage (size, md5Hash), or None when there is no such file."""
    try:
        return get_json("https://www.googleapis.com/storage/v1/b/%s/o/%s" % (bucket, urllib.parse.quote(obj, safe="")))
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


def resolve(want):
    w = (want or "stable").lower()
    if w == "snapshot":
        raise SystemExit("raw Chromium snapshots are built without H.264, AAC and HEVC (build/config/features.gni) - not offered here. "
                         "The newest build with them: ./update.sh canary")
    channels = {"stable": "Stable", "beta": "Beta", "dev": "Dev", "canary": "Canary"}
    if w in channels:
        entry = get_json(CFT + "last-known-good-versions-with-downloads.json")["channels"][channels[w]]
    elif w.isdigit():
        entry = get_json(CFT + "latest-versions-per-milestone-with-downloads.json")["milestones"].get(w)
        if not entry:
            raise SystemExit("Chrome for Testing has no milestone %s" % w)
    elif len(w.split(".")) == 4 and all(p.isdigit() for p in w.split(".")):
        entry = {"version": w}
    else:
        raise SystemExit("unknown build %r: say stable, beta, dev, canary, a milestone (153) or a version (153.0.8010.52)" % want)
    v = entry["version"]
    if "downloads" in entry and not any(d.get("platform") == "linux64" for d in entry["downloads"].get("chrome", [])):
        raise SystemExit("Chrome for Testing %s has no linux64 build" % v)
    obj = "%s/linux64/chrome-linux64.zip" % v
    return {"label": "Chrome for Testing %s (%s)" % (v, w), "name": "cft-" + v, "bucket": "chrome-for-testing-public",
            "object": obj, "url": "https://storage.googleapis.com/chrome-for-testing-public/" + obj, "info": None}


def download(url, path):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r, open(path, "wb") as out:
        total = int(r.headers.get("Content-Length") or 0)
        done, start, shown = 0, time.time(), -10.0
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)
            done += len(chunk)
            now = time.time() - start
            if now - shown >= 2:
                shown = now
                print("  %6.1f%s MB, %.1f MB/s" % (done / 1048576, " of %.1f" % (total / 1048576) if total else "", done / 1048576 / max(now, 0.001)), flush=True)


def verify(path, info):
    size = os.path.getsize(path)
    if str(size) != str(info["size"]):
        raise SystemExit("the download has %d bytes; Google's record of the file says %s" % (size, info["size"]))
    if info.get("md5Hash"):
        h = hashlib.md5()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        want = base64.b64decode(info["md5Hash"]).hex()
        if h.hexdigest() != want:
            raise SystemExit("the download's MD5 is %s; Google's record of the file says %s" % (h.hexdigest(), want))


def extract(zip_path, dest):
    """zipfile forgets Unix permissions; they are put back from each entry (chrome itself must stay executable)."""
    with zipfile.ZipFile(zip_path) as z:
        for info in z.infolist():
            target = os.path.realpath(os.path.join(dest, info.filename))
            if not target.startswith(os.path.realpath(dest) + os.sep):
                raise SystemExit("the archive names a file outside its folder: %r" % info.filename)
            z.extract(info, dest)
            mode = (info.external_attr >> 16) & 0o777
            if mode and not info.is_dir():
                os.chmod(target, mode)


def find_chrome(folder):
    for name in ("chrome-linux64",):
        exe = os.path.join(folder, name, "chrome")
        if os.path.isfile(exe):
            return exe
    return None


def current():
    if not os.path.exists(CURRENT):
        return None
    with open(CURRENT) as f:
        h = dict(l.rstrip("\n").split("=", 1) for l in f if "=" in l)
    exe = find_chrome(os.path.join(BUILDS, h.get("name", "-")))
    if not exe:
        return None
    h["exe"] = exe
    return h


def read_flags():
    out = []
    if os.path.exists(FLAGS):
        with open(FLAGS, encoding="utf-8-sig") as f:
            out = [l.strip() for l in f if l.strip() and not l.strip().startswith("#")]
    return out


def machine_switches(quiet=False):
    """What this machine needs on top of flags.txt."""
    out = []
    nvidia = os.path.exists("/proc/driver/nvidia/version")
    nouveau = os.path.isdir("/sys/module/nouveau")
    wayland = os.environ.get("XDG_SESSION_TYPE") == "wayland" or bool(os.environ.get("WAYLAND_DISPLAY"))
    ozone = os.environ.get("OZONE")  # OZONE=wayland or OZONE=x11 decides it by hand
    if ozone:
        out.append("--ozone-platform=" + ozone)
    elif wayland and nvidia:
        # Chrome on Wayland with NVIDIA's driver loses the card often (black windows, GPU process crashes); through
        # XWayland it keeps it - reported again in 2026 on NVIDIA's forums for Chrome 148 and 154.
        out.append("--ozone-platform=x11")
        if not quiet:
            print("Wayland session with NVIDIA's driver: adding --ozone-platform=x11 (OZONE=wayland turns this off)")
    if nouveau and not quiet:
        print("NOTE: the nouveau driver is loaded. Chromium refuses it outright (software_rendering_list.json entry 30,\n"
              "      'NVIDIA cards with nouveau drivers in Linux are unstable'); --ignore-gpu-blocklist overrides that, but\n"
              "      nouveau cannot clock a 20-series card up - install NVIDIA's own driver for real speed.")
    return out


def cmd_update(want):
    os.makedirs(BUILDS, exist_ok=True)
    b = resolve(want)
    print("newest:", b["label"])
    folder = os.path.join(BUILDS, b["name"])
    exe = find_chrome(folder)
    if exe:
        print("already here:", exe)
    else:
        info = b["info"] or object_info(b["bucket"], b["object"])
        if not info:
            raise SystemExit("Google has no file %s - is the version right?" % b["object"])
        part = os.path.join(BUILDS, b["name"] + ".zip.part")
        print("fetching %s (%.1f MB)" % (b["url"], int(info["size"]) / 1048576))
        download(b["url"], part)
        verify(part, info)
        print("the file agrees with Google's record of it (size and MD5); unpacking")
        tmp = folder + ".unpacking"
        shutil.rmtree(tmp, ignore_errors=True)
        extract(part, tmp)
        os.rename(tmp, folder)
        os.remove(part)
        exe = find_chrome(folder)
        if not exe:
            raise SystemExit("the archive held no chrome (%s)" % folder)
    with open(CURRENT, "w") as f:
        f.write("name=%s\nbuild=%s\nfetched=%s\n" % (b["name"], b["label"], time.strftime("%Y-%m-%d %H:%M")))
    cur = current()
    others = sorted((d for d in os.listdir(BUILDS) if os.path.isdir(os.path.join(BUILDS, d)) and d != b["name"]
                     and d.startswith("cft-") and not d.endswith(".unpacking")),
                    key=lambda d: os.path.getmtime(os.path.join(BUILDS, d)), reverse=True)
    for d in others[KEEP - 1:]:
        shutil.rmtree(os.path.join(BUILDS, d), ignore_errors=True)
        print("removed the older build", d)
    print("in use:", cur["exe"])


def cmd_run(extra):
    cur = current()
    if not cur:
        raise SystemExit("no build here yet: run ./update.sh first")
    args = [cur["exe"]] + read_flags() + machine_switches() + ["--user-data-dir=" + PROFILE, "--no-first-run",
                                                               "--no-default-browser-check", "--enable-logging"] + extra
    print("starting", cur["build"])
    print("  " + " ".join(args))
    os.makedirs(PROFILE, exist_ok=True)
    with open(os.path.join(PROFILE, "run.log"), "ab") as log:  # chromium-latest-linux sent this to /dev/null
        subprocess.Popen(args, stdout=log, stderr=log, start_new_session=True)


def cmd_check(rest):
    cur = current()
    if not cur:
        raise SystemExit("no build here yet: run ./update.sh first")
    keep = "keep" in rest
    extra = [a for a in rest if a != "keep"]
    args = [sys.executable, "-I", os.path.join(TOP, "check", "cdp_check.py"), "--chrome", cur["exe"], "--flags", FLAGS,
            "--profile", CHECK_PROFILE, "--reports", REPORTS] + (["--keep-open"] if keep else [])
    if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        print("no screen here: checking headless (it draws differently from a window - run it at the machine)", flush=True)
        args.append("--headless")
    return subprocess.call(args + ["--"] + machine_switches(quiet=True) + extra)


def cmd_reset():
    names = ("GPUCache", "ShaderCache", "GrShaderCache", "GraphiteDawnCache", "DawnGraphiteCache", "DawnWebGPUCache")
    n = 0
    for base in (PROFILE, os.path.join(PROFILE, "Default")):
        for name in names:
            p = os.path.join(base, name)
            if os.path.isdir(p):
                shutil.rmtree(p)
                print("emptied", p)
                n += 1
    print("nothing to empty" if not n else "done (close this Chromium before emptying, next time it matters)")


def cmd_status():
    cur = current()
    print("build:   ", "%s, fetched %s" % (cur["build"], cur.get("fetched")) if cur else "none yet: run ./update.sh")
    if cur:
        print("chrome:  ", cur["exe"])
    for f in read_flags():
        print("switch:  ", f)
    for f in machine_switches(quiet=True):
        print("added:   ", f, "(this machine)")
    try:
        with open("/proc/driver/nvidia/version") as f:
            print("driver:  ", f.readline().strip())
    except OSError:
        print("driver:  ", "no NVIDIA driver loaded" + (" (nouveau is)" if os.path.isdir("/sys/module/nouveau") else ""))
    print("session: ", os.environ.get("XDG_SESSION_TYPE", "?"))


def main(argv):
    cmd = argv[0] if argv else "help"
    rest = argv[1:]
    if cmd == "update":
        cmd_update(rest[0] if rest else None)
    elif cmd == "run":
        cmd_run(rest)
    elif cmd == "check":
        return cmd_check(rest)
    elif cmd == "reset":
        cmd_reset()
    elif cmd == "status":
        cmd_status()
    else:
        print(__doc__)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
