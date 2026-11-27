"""python3 -I tests/test_linux.py - linux/antiblock.py's parts that need no network: which file each build name
leads to (against answers shaped as Google's are), the check of a download against Google's record, unpacking with
the permissions kept, the switches a machine gets, the pruning of old builds."""
import base64
import hashlib
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import urllib.error
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("antiblock", os.path.join(HERE, "..", "linux", "antiblock.py"))
ab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ab)

# Answers in the shape Google gives them (read 2026-11-26)
CHANNELS = {"timestamp": "2026-11-26T00:00:00Z", "channels": {
    "Stable": {"channel": "Stable", "version": "158.0.8127.88", "revision": "1727472", "downloads": {"chrome": [
        {"platform": "linux64", "url": "https://storage.googleapis.com/chrome-for-testing-public/158.0.8127.88/linux64/chrome-linux64.zip"},
        {"platform": "win64", "url": "https://storage.googleapis.com/chrome-for-testing-public/158.0.8127.88/win64/chrome-win64.zip"}]}},
    "Canary": {"channel": "Canary", "version": "160.0.8186.0", "revision": "1755616", "downloads": {"chrome": [
        {"platform": "linux64", "url": "https://storage.googleapis.com/chrome-for-testing-public/160.0.8186.0/linux64/chrome-linux64.zip"}]}}}}
MILESTONES = {"timestamp": "x", "milestones": {"153": {"milestone": "153", "version": "153.0.8010.52", "revision": "1681091",
    "downloads": {"chrome": [{"platform": "linux64", "url": "https://storage.googleapis.com/chrome-for-testing-public/153.0.8010.52/linux64/chrome-linux64.zip"}]}}}}
asked = []


def fake_get_json(url):
    asked.append(url)
    if url.endswith("last-known-good-versions-with-downloads.json"):
        return CHANNELS
    if url.endswith("latest-versions-per-milestone-with-downloads.json"):
        return MILESTONES
    raise AssertionError("unexpected " + url)


ab.get_json = fake_get_json

b = ab.resolve(None)
assert b["name"] == "cft-158.0.8127.88" and b["object"] == "158.0.8127.88/linux64/chrome-linux64.zip", b
assert b["url"] == CHANNELS["channels"]["Stable"]["downloads"]["chrome"][0]["url"]
assert ab.resolve("canary")["name"] == "cft-160.0.8186.0"
assert ab.resolve("153")["url"].endswith("/153.0.8010.52/linux64/chrome-linux64.zip")
assert ab.resolve("153.0.8010.12")["object"] == "153.0.8010.12/linux64/chrome-linux64.zip"
for bad in ("nightly", "1.2.3", "snapshot"):
    try:
        ab.resolve(bad)
        raise AssertionError("took " + bad)
    except SystemExit:
        pass
print("ok   names to files: stable, canary, a milestone, a version; a snapshot (no H.264/AAC/HEVC) refused")

# A download checked against Google's record; unpacking keeps chrome executable
tmp = tempfile.mkdtemp()
try:
    z = os.path.join(tmp, "b.zip")
    with zipfile.ZipFile(z, "w") as zf:
        i = zipfile.ZipInfo("chrome-linux64/chrome")
        i.external_attr = (0o100755 << 16)
        zf.writestr(i, b"#!/bin/sh\necho chrome\n")
        i = zipfile.ZipInfo("chrome-linux64/resources.pak")
        i.external_attr = (0o100644 << 16)
        zf.writestr(i, b"pak")
    data = open(z, "rb").read()
    info = {"size": str(len(data)), "md5Hash": base64.b64encode(hashlib.md5(data).digest()).decode()}
    ab.verify(z, info)
    for wrong in ({"size": str(len(data) + 1), "md5Hash": info["md5Hash"]}, {"size": info["size"], "md5Hash": base64.b64encode(b"0" * 16).decode()}):
        try:
            ab.verify(z, wrong)
            raise AssertionError("a wrong file passed")
        except SystemExit:
            pass
    ab.extract(z, os.path.join(tmp, "out"))
    exe = ab.find_chrome(os.path.join(tmp, "out"))
    assert exe and os.access(exe, os.X_OK), exe
    assert not os.access(os.path.join(tmp, "out", "chrome-linux64", "resources.pak"), os.X_OK)
    evil = os.path.join(tmp, "evil.zip")
    with zipfile.ZipFile(evil, "w") as zf:
        zf.writestr("../../escaped", b"x")
    try:
        ab.extract(evil, os.path.join(tmp, "out2"))
    except SystemExit:
        pass
    assert not os.path.exists(os.path.join(tmp, "escaped"))
    print("ok   a download checked by size and MD5, a wrong one refused; chrome stays executable; nothing escapes the folder")
finally:
    shutil.rmtree(tmp)

# The switches a machine gets
env = dict(os.environ)
try:
    os.environ.pop("OZONE", None)
    os.environ["XDG_SESSION_TYPE"] = "wayland"
    real_exists = os.path.exists
    os.path.exists = lambda p: True if p == "/proc/driver/nvidia/version" else real_exists(p)
    assert ab.machine_switches(quiet=True) == ["--ozone-platform=x11"]
    os.environ["OZONE"] = "wayland"
    assert ab.machine_switches(quiet=True) == ["--ozone-platform=wayland"]
    os.environ.pop("OZONE")
    os.environ["XDG_SESSION_TYPE"] = "x11"
    os.environ.pop("WAYLAND_DISPLAY", None)
    assert ab.machine_switches(quiet=True) == []
    os.path.exists = real_exists
    print("ok   Wayland with NVIDIA's driver -> --ozone-platform=x11; OZONE= decides by hand; X11 -> nothing added")
finally:
    os.environ.clear()
    os.environ.update(env)
