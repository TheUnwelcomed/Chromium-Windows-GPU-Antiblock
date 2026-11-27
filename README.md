# Chromium-Windows-GPU-Antiblock

Chrome for Testing on Windows that draws on the graphics card and plays H.264, AAC and HEVC. It comes with a check
that reports, line by line, what the browser does with the card and with each codec. Built for testing
[Unwelcomed-IPTV](https://github.com/TheUnwelcomed/Unwelcomed-IPTV) on a Windows 10 machine with an RTX 2060 SUPER.
The Admin-Gate's emulator cores and the new Windows engine need WebGL 2 on the card, and the channels need H.264/AAC.

`linux/` has the same tools for Linux (RHEL 9). It is the original
[scheib/chromium-latest-linux](https://github.com/scheib/chromium-latest-linux), redone.

## Use it (Windows 10 or 11)

1. **Code → Download ZIP**, unzip anywhere (or `git clone`). Windows marks files from a downloaded ZIP: right-click
   the ZIP → Properties → **Unblock** before unzipping, or answer **Run** when Windows asks about a `.cmd` file.
2. Double-click **`update.cmd`**. It downloads Chrome for Testing stable (about 215 MB), checks the file against
   Google's own record of it (size and MD5), and unpacks it into `builds\`.
3. Double-click **`run.cmd`**. It starts the browser with the switches in [`flags.txt`](flags.txt), using a profile of
   its own in `profile\`. Any installed Chrome and its profile are left alone.
4. Double-click **`check.cmd`**. It starts the browser once more in a fresh profile and asks it, through its own
   debugging port, what it does with the card. Each finding prints as one line marked `ok`, `FAIL` or `--` (said, not
   judged). The full report, including chrome://gpu's own text, goes to `reports\gpu-check-<time>.txt`. That file is
   the one to send back.

| Command | What it does |
|---|---|
| `update.cmd [stable\|beta\|dev\|canary\|153\|153.0.8010.52]` | fetch Chrome for Testing: a channel, the newest of a milestone, or one exact version. The newest build with the codecs is `canary` |
| `run.cmd [URL] [--switch]` | start it with `flags.txt`; anything after goes to the browser |
| `check.cmd [keep] [--switch]` | the check; `keep` leaves the window open, a `--switch` is tried once without touching `flags.txt` |
| `run.cmd edge`, `check.cmd edge` | the same with the Microsoft Edge already on the machine (own profile `profile-edge\`): the one Chromium browser on Windows that plays Dolby AC-3/E-AC-3 |
| `reset-gpu-cache.cmd [edge]` | empty the shader and GPU caches of the profile (bookmarks and logins stay) |
| `status.cmd` | the build in use, the switches, what Windows says about the session and each display adapter |
| `update-and-run.cmd` | both |
| `build\build-chromium.cmd` | **build your own Chromium with every codec Windows can decode**, AC-3/E-AC-3 included, on this PC: [build/README.md](build/README.md) |

All of it is `antiblock.ps1` (Windows PowerShell 5.1, which Windows 10 has; nothing to install). The `.cmd` files only
run it with `-ExecutionPolicy Bypass`, so double-clicking works.

## Which browser for the Admin-Gate

**Chrome**, meaning the Chrome for Testing `run.cmd` starts. The gate was built and proven in Chrome
(Unwelcomed-IPTV `docs/ADMIN-GATE.md` 8zd), and Chrome gives the sealed frame everything its programs need: WebGL 2
on the card (the Dreamcast and PSP cores, the new Windows engine), WebAssembly with SIMD, tail calls and standard
exceptions, JSPI (GnollHack), 2 GB of memory at once, and threads where the site sends its isolation headers.
**Edge** (`run.cmd edge`) is the same engine. **Firefox** on the owner's Windows machine has no WebGL, so the
Dreamcast and PSP cores cannot draw there.

`check.cmd` builds a frame exactly as the gate does (`sandbox="allow-scripts"`, origin `null`, the same `allow`
words) and asks it what the gate's own browser check asks, using the same WebAssembly module bytes. Its `gate frame:`
lines must all say `ok`. On the admin site itself, Ctrl+Alt+B in the Emulator's list is the gate's own check. Its
*graphics path* line should read `WebGL 2, by ANGLE (NVIDIA, NVIDIA GeForce RTX 2060 SUPER ...)`, without "drawn by
the processor".

## What was found (2026-11-26)

Everything below was read in Chromium's own source at the build the owner runs (160.0.8187.0, cloned the same day).

**The owner's chrome://gpu (photo, Chromium 160.0.8187.0 on Windows 10 19045).** Canvas, Compositing, Rasterization,
Video Decode/Encode and WebGPU were all *Hardware accelerated*. Only **WebGL read "Disabled"** (and WebNN, which is
normal). In Chromium that status has exactly one cause when the rest of the card works: **the `--disable-webgl` switch
on the browser's command line** (`content/browser/gpu/compositor_util.cc`). A feature the blocklist refuses reads
*Unavailable* instead. chrome://gpu describes the problem as "WebGL has been disabled via blocklist or the command
line", which is easy to read as a blocklist. The fix is to remove `--disable-webgl` from the shortcut. `check.cmd`
catches this and any similar switch by name.

**What Chromium's GPU blocklist holds for NVIDIA on Windows** (`gpu/config/software_rendering_list.json`). Only drivers
from 2009 to 2018 (entries 59, 90, 91, 142, 164, 175) and three old cards (8, 72, 136). Nothing on the list matches a
2060 SUPER with a current driver. The entry that does black out a good card is **74**: when Windows gives the browser
the *Microsoft Basic Render Driver* instead of the card, everything is blocked. That happens over Remote Desktop, in a
virtual machine, or when the NVIDIA driver has stopped (Device Manager Code 43). `check.cmd` and `status.cmd` say
which case it is.

**The other way the card gets lost.** After 3 GPU process crashes within a few minutes, Chromium switches to drawing on
the processor for the rest of the session, and WebGL goes with it (`content/browser/gpu/gpu_process_host.cc`,
`fallback.md`). From the outside that also looks like a blocklist. `flags.txt` turns the fallback off, so a crash
shows up as a crash. The check counts crashes and quotes the browser log.

## The switches (`flags.txt`)

One switch per line. A line starting with `#` is a comment, so a `#` turns a switch off. Each switch was checked to
exist in Chromium 160's source:

| Switch | Defined in | Why |
|---|---|---|
| `--ignore-gpu-blocklist` | `gpu/config/gpu_switches.cc` | skip the blocklist entirely (`gpu_util.cc` then never consults it) |
| `--force-high-performance-gpu` | `gpu/config/gpu_switches.cc` | with two or more adapters, draw everything on the high-performance one, i.e. the card (`gpu_init.cc`) |
| `--disable-gpu-process-crash-limit` | `content/public/common/content_switches.cc` | no quiet switch to software after crashes |
| `--enable-gpu-rasterization` | `gpu/config/gpu_switches.cc` | draw page content on the card |
| `--use-adapter-luid=H,L` (off) | `ui/gl/gl_switches.cc` | pin one adapter. `check.cmd` prints this line with the right numbers when another adapter is drawing |

`update.cmd` also sets the Windows setting *Graphics → High performance* for the downloaded `chrome.exe`
(`HKCU\Software\Microsoft\DirectX\UserGpuPreferences`, the same value the Settings app writes). `forget` removes it
again: `powershell -ExecutionPolicy Bypass -File antiblock.ps1 forget`.

Never add `--disable-webgl`, `--disable-webgl2`, `--disable-3d-apis`, `--disable-gpu`, `--disable-gpu-compositing`,
`--use-angle=swiftshader` or `--use-angle=warp`. Each one turns off the card or WebGL, and the check marks it FAIL.

## Codecs

**The easy way, no building:** Chrome for Testing (`update.cmd`, `run.cmd`) plays H.264, AAC and HEVC. For a channel
with Dolby (AC-3/E-AC-3) sound, Jellyfin converts just the sound to AAC for it, and the picture is still copied. To
have Dolby play as it is, use **`run.cmd edge`**: the Edge already on the PC, with the same GPU switches. Building your
own (`build\`) is only for having everything in one Chromium.

From `build/config/features.gni` and `media/media_options.gni` at 160.0.8187.0, and from the check run on Chrome for
Testing 153:

| | Chrome for Testing (`update.cmd`) | your own build (`build\build-chromium.cmd`) | Microsoft Edge (`run.cmd edge`) | raw Chromium snapshot |
|---|---|---|---|---|
| H.264, AAC | yes | yes | yes | **no** |
| HEVC / HEVC 10-bit | yes, decoded on the card (the 2060 SUPER has HEVC decode) | yes, on the card | with the HEVC Video Extensions from the Microsoft Store (Microsoft's own Edge guide) | **no** |
| AC-3 / E-AC-3 (Dolby) | no: compiled out of Chrome on Windows | **yes**, through Windows 10's own Dolby decoder | yes, the same decoder | no |
| DTS | no: compiled out | no (see build/README.md) | `check.cmd edge` says | no |
| VP9, AV1, Opus, FLAC, MP3 | yes (AV1 on the processor: the 2060 has no AV1 decoder) | yes | `check.cmd edge` says | yes |
| MPEG-TS in MSE, HLS without a script | yes | yes | `check.cmd edge` says | no |

Raw snapshots are therefore not offered (`update.cmd snapshot` refuses and explains why). Where a browser can't play
an audio codec, Jellyfin turns it into AAC for that browser, which costs little. MPEG-2 video plays in no Chromium
browser, so Jellyfin transcodes it. Dolby Vision stays as Chromium ships it: unencrypted Dolby Vision is off by default
(`media/media_options.gni`). Profile 8 still plays as its HEVC layer, and Jellyfin tone-maps profile 5.

## When check.cmd says FAIL

| Line | Meaning and fix |
|---|---|
| `switch on the command line  --disable-webgl ...` | remove it from the shortcut or `flags.txt` |
| `active GPU  the Microsoft Basic Render Driver` | Remote Desktop, a VM, or the NVIDIA driver stopped. Run at the machine itself; `status.cmd` shows the driver state |
| `NVIDIA card drawing  no ... Add this line to flags.txt: --use-adapter-luid=...` | do exactly that, then run `check.cmd` again |
| `fell back to software`, `GPU process crashes  N` | the GPU process crashed. Programs that hook into Direct3D also run inside the browser's GPU process: overlays and recorders, for example RivaTuner Statistics Server, which comes with MSI Afterburner. Close them, run `reset-gpu-cache.cmd`, and check again. If it still crashes, take the `#` off `--disable-skia-graphite` in `flags.txt` |
| `H.264` / `AAC` | not Chrome for Testing: run `update.cmd` |
| `HEVC` | hardware video decoding is off, or the card has no HEVC decoder |
| `shader work ... the processor drawing` | WebGL works, but on the processor |
| `Chromium  did not open its debugging port ... (exited: True)` | from a copy before 2026-11-26 run as administrator: since 2025 Chrome and Edge, started as administrator, start themselves again as the signed-in user and the first process ends at once (`chrome_main_delegate.cc`, `MaybeAutoDeElevate`). The current `check.cmd` waits for the browser that took over. Administrator is not needed for any of these files |
| `clock, cost of a reading` | the browser's clock is slow to read; the Dreamcast core reads it about 150,000 times a second. Usually Windows told to use the HPET timer: `bcdedit /enum {current}` in an administrator command prompt; a line `useplatformclock Yes` is it, and `bcdedit /deletevalue useplatformclock` and a restart undo it |
| `clock, finest step` | the browser found no steady processor clock and times everything by Windows' millisecond timer |

## Linux (`linux/`, RHEL 9)

```
cd linux
./update.sh          # Chrome for Testing linux64, checked like on Windows
./run.sh             # flags.txt; adds --ozone-platform=x11 on a Wayland session with NVIDIA's driver
./check.sh           # the same check (python3, nothing to install)
```

On Linux the blocklist refuses nouveau (entry 30, "NVIDIA cards with nouveau drivers in Linux are unstable"), software
GL such as llvmpipe (3) and NVIDIA drivers older than 295 (47). `run.sh` says so when nouveau is loaded. Chrome on
Wayland with NVIDIA's driver keeps losing the card, and through XWayland it keeps it, so `run.sh` picks X11 there
(`OZONE=wayland ./run.sh` overrides). Hardware video decoding on NVIDIA needs VA-API, which Chromium keeps off on
NVIDIA (`media/base/media_switches.cc`: "NVIDIA VA-API drivers do not support Chromium and can sometimes cause
crashes"). That means no HEVC in Chrome on that machine unless the optional line in `linux/flags.txt` works with
nvidia-vaapi-driver. EPEL's own Chromium for RHEL 9 is built without H.264 too, so Chrome for Testing is the one to
use there as well.

## Files

| File | What it is |
|---|---|
| `antiblock.ps1` | everything on Windows: update, run, check, reset, status, forget |
| `*.cmd` | double-click wrappers |
| `flags.txt` | the switches, with the reason for each |
| `check/gpu-check.html` | the page the check opens. It also works on its own: open it in any browser. WebGL 2 and who draws it, the Admin-Gate's sealed frame and what its programs need, a timed shader, WebGPU, every codec above, hardware decoding, refresh rate |
| `check/gpu-judge.js` | runs inside chrome://gpu and turns Chromium's own GPU record into ok/FAIL lines. Shared by the Windows and the Linux check |
| `check/cdp_check.py` | the check in Python (used by `linux/check.sh`; also runs on Windows where Python is installed) |
| `build/` | building Chromium with every codec on this PC: `build-chromium.cmd`, `build-chromium.ps1`, `args.gn`, and how-to ([build/README.md](build/README.md)) |
| `linux/` | the Linux scripts |
| `tests/` | `node tests/test_judge.mjs` runs the judge against made-up chrome://gpu data for the Windows cases, including the photo's exact state. `python3 -I tests/test_linux.py` covers the Linux downloader without a network |

**Not run here either:** `build/build-chromium.ps1` (no Windows; syntax checked, every argument, path and
requirement read in Chromium 158.0.8127.88's source).

**Tested here** (a Linux machine without a graphics card): the check end to end against Chrome for Testing 153. It
correctly calls the software renderer a FAIL, H.264/AAC ok, HEVC FAIL with no card to decode it, and names the
switches that turn the card off. The judge tests and Linux tests pass. **Not run here:** `antiblock.ps1` itself (no
Windows here). It was written for Windows PowerShell 5.1 and checked for syntax only. Its first real run is on the
owner's machine.

## Credits

The Linux scripts started from [scheib/chromium-latest-linux](https://github.com/scheib/chromium-latest-linux)
(Apache-2.0; see [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md) for what changed). Written with Claude for TheUnwelcomed.
