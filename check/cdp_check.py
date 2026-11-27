#!/usr/bin/env python3
"""What Chromium does with the graphics card, asked of Chromium itself - Python 3.8+, nothing to install.

    python3 -I check/cdp_check.py --chrome PATH [--flags FILE] [--profile DIR] [--reports DIR] [--headless]
                                  [--keep-open] [-- MORE CHROMIUM SWITCHES]

linux/check.sh runs this; on Windows check.cmd does the same in PowerShell (antiblock.ps1), and this file works there
too where Python is installed. It starts Chromium with the switches of the flags file in a fresh profile of its own
(so no setting of an everyday profile can turn the card off), and through the browser's debugging port reads:

  * Chromium's own record of the GPU (the same data chrome://gpu shows): every adapter, which one is active, each
    feature's status, the "Problems Detected" with their reasons, whether the GPU process fell back to software,
    how often it crashed, the driver bug workarounds in force;
  * check/gpu-check.html run in a tab: WebGL 2 and who draws it, a timed shader, WebGPU, H.264/AAC and the other
    codecs, hardware decoding.

Prints one line per finding, "ok", "FAIL" or "--" (said, not judged), and writes everything - with chrome://gpu's
full report text - to a file in the reports folder. Exit status: 0 when no line says FAIL, 1 otherwise, 2 when
Chromium could not be asked at all.
"""
import argparse
import base64
import json
import os
import pathlib
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
def read_flags(path):
    """One switch a line; a line whose first character (after spaces) is # is a note."""
    flags = []
    if path and os.path.exists(path):
        with open(path, encoding="utf-8-sig") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    flags.append(line)
    return flags


class DevTools:
    """The smallest WebSocket client that talks to Chromium's DevTools endpoint (RFC 6455: text frames, masked)."""

    def __init__(self, port, path, timeout=60):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(("GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % (path, port, key)).encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("DevTools closed the connection during the handshake")
            head += chunk
        head, self.buf = head.split(b"\r\n\r\n", 1)
        if b" 101 " not in head.split(b"\r\n", 1)[0]:
            raise ConnectionError("DevTools refused the WebSocket: %r" % head[:200])
        self.next_id = 0

    def _recv_exact(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("DevTools closed the connection")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _send_frame(self, opcode, payload):
        head = bytes([0x80 | opcode])
        n = len(payload)
        if n < 126:
            head += bytes([0x80 | n])
        elif n < 65536:
            head += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            head += bytes([0x80 | 127]) + struct.pack(">Q", n)
        mask = os.urandom(4)
        self.sock.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def _recv_message(self):
        parts = []
        while True:
            b0, b1 = self._recv_exact(2)
            opcode, n = b0 & 0x0F, b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._recv_exact(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._recv_exact(8))[0]
            mask = self._recv_exact(4) if b1 & 0x80 else None
            data = self._recv_exact(n)
            if mask:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            if opcode == 0x9:  # ping
                self._send_frame(0xA, data)
                continue
            if opcode == 0x8:
                raise ConnectionError("DevTools closed the connection")
            if opcode in (0x1, 0x2, 0x0):
                parts.append(data)
                if b0 & 0x80:
                    return b"".join(parts).decode("utf-8", "replace")

    def call(self, method, params=None, session=None, timeout=60):
        self.next_id += 1
        msg = {"id": self.next_id, "method": method, "params": params or {}}
        if session:
            msg["sessionId"] = session
        self._send_frame(0x1, json.dumps(msg).encode())
        end = time.time() + timeout
        while time.time() < end:
            reply = json.loads(self._recv_message())
            if reply.get("id") == self.next_id:
                if "error" in reply:
                    raise RuntimeError("%s: %s" % (method, reply["error"].get("message")))
                return reply.get("result", {})
        raise TimeoutError(method)

    def evaluate(self, session, expression, timeout=60):
        r = self.call("Runtime.evaluate", {"expression": expression, "awaitPromise": True, "returnByValue": True,
                                           "timeout": timeout * 1000}, session, timeout + 5)
        if "exceptionDetails" in r:
            raise RuntimeError(r["exceptionDetails"].get("exception", {}).get("description") or r["exceptionDetails"].get("text"))
        return r.get("result", {}).get("value")

    def open_tab(self, url, timeout=60):
        """A new tab at url; returns its session once the page there has loaded (a new tab starts on about:blank)."""
        target = self.call("Target.createTarget", {"url": url})["targetId"]
        session = self.call("Target.attachToTarget", {"targetId": target, "flatten": True})["sessionId"]
        want = url.split("#")[0].rstrip("/")
        end = time.time() + timeout
        while time.time() < end:
            try:
                here = self.evaluate(session, "location.href.split('#')[0].replace(/\\/$/, '') + ' ' + document.readyState", 10)
                if here and here.rsplit(" ", 1)[0] == want and here.endswith(" complete"):
                    return session
            except Exception:
                pass  # the page was being replaced while asked
            time.sleep(0.2)
        raise TimeoutError("the tab did not reach " + url)


def fetch_string(dt, session, name, length, piece=200000):
    """A long string left in the page (window[name]) fetched in pieces, as antiblock.ps1 does."""
    out = []
    for at in range(0, int(length or 0), piece):
        out.append(dt.evaluate(session, "window[%s].substr(%d, %d)" % (json.dumps(name), at, piece)) or "")
    return "".join(out)


LOG_LINES = r"GPU process (has crashed|exited unexpectedly|isn't usable)|Exiting GPU process|GPU process launch failed"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--chrome", required=True, help="chrome or chrome.exe to check")
    ap.add_argument("--flags", default=None, help="the flags file (default: none)")
    ap.add_argument("--profile", default=None, help="profile folder for the check (emptied first; default: a temporary one)")
    ap.add_argument("--reports", default=os.getcwd(), help="where the report file goes (default: here)")
    ap.add_argument("--page", default=os.path.join(HERE, "gpu-check.html"))
    ap.add_argument("--headless", action="store_true", help="no window (headless Chromium draws differently: use only where there is no screen)")
    ap.add_argument("--keep-open", action="store_true", help="leave the browser open at the end")
    ap.add_argument("--timeout", type=int, default=90)
    ap.add_argument("extra", nargs="*", help="more Chromium switches, after --")
    a = ap.parse_args()

    flags = read_flags(a.flags) + a.extra
    temp = a.profile is None
    profile = a.profile or tempfile.mkdtemp(prefix="gpu-check-")
    if not temp and os.path.isdir(profile):
        shutil.rmtree(profile, ignore_errors=True)
    os.makedirs(profile, exist_ok=True)
    args = [a.chrome] + flags + ["--user-data-dir=" + profile, "--remote-debugging-port=0", "--no-first-run",
                                 "--no-default-browser-check", "--enable-logging", "--v=0"]
    if a.headless:
        args.append("--headless")
    args.append("about:blank")
    started = time.strftime("%Y%m%d-%H%M%S")
    lines = []

    def say(verdict, key, text):
        lines.append((verdict, key, str(text)))
        print("%-4s %-28s %s" % (verdict, key, text), flush=True)

    proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    port_file = os.path.join(profile, "DevToolsActivePort")
    end = time.time() + a.timeout
    while not os.path.exists(port_file) and time.time() < end and proc.poll() is None:
        time.sleep(0.2)
    if not os.path.exists(port_file):
        print("FAIL Chromium did not open its debugging port (exit code %s): %s" % (proc.poll(), " ".join(args)))
        return 2
    time.sleep(0.3)
    with open(port_file) as f:
        port, path = f.read().split("\n")[:2]
    try:
        dt = DevTools(int(port), path.strip(), timeout=a.timeout)
    except Exception as e:
        print("FAIL could not talk to Chromium's debugging port: %s" % e)
        proc.kill()
        return 2
    sysinfo, judged, report_text, data_text, page = "", {}, "", "", {}
    try:
        try:
            sysinfo = json.dumps(dt.call("SystemInfo.getInfo"), indent=1)
        except Exception as e:
            sysinfo = "not answered: %s" % e
        with open(os.path.join(HERE, "gpu-judge.js"), encoding="utf-8") as f:
            judge_js = f.read()
        s1 = dt.open_tab("chrome://gpu", a.timeout)
        judged = json.loads(dt.evaluate(s1, judge_js, a.timeout) or "{}")
        if judged.get("error"):
            say("FAIL", "chrome://gpu", judged["error"])
        else:
            report_text = fetch_string(dt, s1, "__gpuReport", judged.get("reportLength"))
            data_text = fetch_string(dt, s1, "__gpuData", judged.get("dataLength"))
        s2 = dt.open_tab(pathlib.Path(os.path.abspath(a.page)).as_uri(), a.timeout)
        page = json.loads(dt.evaluate(s2, "window.gpuCheck.then(r => JSON.stringify(r))", a.timeout) or "{}")
    except Exception as e:  # say what went wrong, and still write what was read
        say("FAIL", "the check itself", "%s: %s" % (type(e).__name__, e))
    finally:
        if not a.keep_open:
            try:
                dt.call("Browser.close", timeout=10)
            except Exception:
                pass
            try:
                proc.wait(15)
            except subprocess.TimeoutExpired:
                proc.kill()
    log_text = ""
    log_path = os.path.join(profile, "chrome_debug.log")
    if os.path.exists(log_path):
        with open(log_path, encoding="utf-8", errors="replace") as f:
            log_text = f.read()
    for l in judged.get("lines") or []:
        say(l["verdict"], l["key"], l["text"])
    for line in log_text.splitlines():
        if re.search(LOG_LINES, line):
            say("--", "browser log", line.strip()[:300])
    for l in page.get("lines") or []:
        say(l["verdict"], l["key"], l["text"])
    pin = judged.get("pin")
    os.makedirs(a.reports, exist_ok=True)
    report = os.path.join(a.reports, "gpu-check-%s.txt" % started)
    with open(report, "w", encoding="utf-8") as f:
        f.write("GPU check, %s\nChromium: %s\nSwitches: %s\n\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), a.chrome, " ".join(args[1:])))
        for v, k, t in lines:
            f.write("%-4s %-28s %s\n" % (v, k, t))
        f.write("\n==== chrome://gpu, as its own report ====\n%s\n" % report_text)
        f.write("\n==== chrome://gpu, the data (JSON) ====\n%s\n" % data_text)
        f.write("\n==== DevTools SystemInfo.getInfo (JSON) ====\n%s\n" % sysinfo)
        tail = [l for l in log_text.splitlines() if re.search(r"gpu|GPU|angle|ANGLE|d3d|D3D|vulkan|EGL|GLX", l)][-200:]
        f.write("\n==== browser log, GPU lines (last 200) ====\n%s\n" % "\n".join(tail))
    failed = sum(1 for v, _, _ in lines if v == "FAIL")
    print("\n%s - report: %s" % ("every checked line ok" if not failed else "%d line(s) FAIL" % failed, report))
    if pin:
        print("To pin the NVIDIA card, add to flags.txt:  %s" % pin)
    if temp:
        shutil.rmtree(profile, ignore_errors=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
