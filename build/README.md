# Build Chromium with every codec Windows can decode

Chrome for Testing plays H.264, AAC and HEVC, but Google compiles **AC-3 and E-AC-3 (Dolby Digital / Digital Plus)**
out of every Chrome build for Windows (`media/media_options.gni` turns `enable_platform_ac3_eac3_audio` on only for
Cast devices and tvOS). A build of your own with that switch on decodes them through the Dolby decoder Windows 10
already has (`media/filters/win/media_foundation_audio_decoder.cc`). This folder makes that build on your own
Windows PC, and the launcher one folder up runs and checks it like any other build.

## What it needs

From Chromium's own Windows build guide (`docs/windows_build_instructions.md` at 158.0.8127.88):

| | |
|---|---|
| Windows | 10 or 11, 64-bit (Visual Studio 2026 supports Windows 10; under Extended Security Updates, with the ESU patches installed) |
| Disk | about 100 GB free on an NTFS drive (120 GB for the first run), in a folder whose path has no spaces |
| Memory | Chromium asks for 8 GB and calls more than 16 GB "highly recommended". The script caps the parallel jobs at half the GB |
| Visual Studio 2026 | version 18.0 or newer. Community is free. Install "Desktop development with C++" and its "C++ ATL/MFC" part |
| Windows 11 SDK | **10.0.28000** (Visual Studio Installer → Individual components; it installs on Windows 10). Then Control Panel → Programs and Features → Windows Software Development Kit → Change → tick **Debugging Tools for Windows** (10.0.26100.3323 or newer is required) |
| Git | Git for Windows |
| Time | tens of GB to download, then a build of many hours. Most of a day on a 12-thread machine |

Before the first build, open an administrator PowerShell once and run `Add-MpPreference -ExclusionPath C:\chromium`.
Chromium's guide names Defender scanning as the most common cause of a slow build.

## Build

Double-click **`build-chromium.cmd`**, or run it from a command prompt with options:

| Option | |
|---|---|
| `158.0.8127.88` | the version to build. Default: the version of stable Chrome for Testing (what `update.cmd` fetches). `canary`, `beta` and `dev` also work |
| `dir=D:\chromium` | where depot_tools and the checkout go (default `C:\chromium`) |
| `jobs=8` | compile jobs at once (default: one per processor, at most half the memory in GB) |
| `official` | optimized (PGO + ThinLTO), as Google's own builds are. A faster browser, about twice the build time, and about 32 GB of RAM for the link |

It checks the machine first and stops with `FAIL` lines, downloading nothing, if something above is missing. Then it
runs these steps:
1. depot_tools (Chromium's tools), using your Visual Studio (`DEPOT_TOOLS_WIN_TOOLCHAIN=0`).
2. The source of exactly that version: `git clone -b VERSION --depth=2`, then `gclient sync --no-history` for its
   dependencies and `gclient runhooks`.
3. `gn gen` with [`args.gn`](args.gn), then `autoninja ... chrome`. **If anything stops it, run it again: it carries
   on** from the last finished step, and the compile resumes where it was.
4. It copies the browser into `builds\custom-VERSION\chrome-win64\`, file by file as Chromium's own Windows archive
   is made (`infra\archive_config\win-archive-rel.json` in the checkout), and makes it the build `run.cmd` and
   `check.cmd` use.

Then run **`check.cmd`**. The AC-3 and E-AC-3 lines should say `plays`, alongside H.264, AAC and HEVC.

`update.cmd` switches back to Chrome for Testing. `powershell -ExecutionPolicy Bypass -File antiblock.ps1 use
custom-VERSION` switches back to your build. `update.cmd` never deletes a build you made.

## What args.gn turns on

| Argument | Defined in | What |
|---|---|---|
| `proprietary_codecs = true` | `build/config/features.gni` | H.264, AAC, MP3, native HLS, MPEG-TS in MSE |
| `ffmpeg_branding = "Chrome"` | `third_party/ffmpeg/ffmpeg_options.gni` | FFmpeg's H.264, AAC and MP3 decoders |
| `enable_platform_hevc`, `enable_hevc_parser_and_hw_decoder` | `media/media_options.gni` | HEVC and HEVC 10-bit, decoded by the graphics card (the 2060 SUPER decodes both) |
| `enable_platform_ac3_eac3_audio = true` | `media/media_options.gni` | AC-3 / E-AC-3 through Windows' Dolby decoder |
| `is_debug = false`, `symbol_level = 0`, `dcheck_always_on = false` | `build/config/` | a release build without debug symbols or debug checks |

Left off on purpose:
- **DTS.** On Windows it links Microsoft's VCRTForwarders packages (`media/filters/BUILD.gn`), which a public checkout
  may not have, and Windows 10 has no DTS decoder of its own.
- **Unencrypted Dolby Vision.** It stays as Chromium ships it. Profile 8 plays as HEVC.
- **MPEG-2 video.** Chromium's FFmpeg has no MPEG-2 decoder, and no switch adds one.

## The rootless server instead (possible, not recommended)

Chromium can be cross-built for Windows on Linux (`docs/win_cross.md`), so the Bytesized host could do the compiling.
Three things weigh against it:

1. **Visual Studio 2026 must still be installed on a Windows machine.** The Windows SDK and compiler libraries are
   packaged there once and copied to the server. Once that is done on your PC, building there is simpler.
2. **The shared host's own rule** (RUFFLE5, `docs/findings-2026-10-21.md`): 16 parallel compiles took the server down,
   so every build there runs at `JOBS=4` under `nice`/`ionice`. At 4 jobs, Chromium is a build of days, not hours.
3. Cross builds stub out the `.asm` files, so Crashpad can't report crashes (`docs/win_cross.md`).

If you want it anyway, in Chromium's documented order:

```
# On the Windows PC (Visual Studio 2026 and the 10.0.28000 SDK installed; depot_tools as build-chromium.cmd sets it up):
cd C:\chromium\depot_tools\win_toolchain
python3 package_from_installed.py 2026 -w 10.0.28000.0 --noarm
#   -> <hash>.zip: copy it to the server, e.g. into ~/win_toolchain/

# On the server (no root needed: depot_tools, the compilers and the Linux sysroot are all downloaded into ~):
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git ~/chromium/depot_tools
export PATH=$HOME/chromium/depot_tools:$PATH
export DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL=$HOME/win_toolchain
export GYP_MSVS_HASH_<toolchain hash>=<the zip's hash>   # gclient runhooks prints the toolchain hash it wants
cd ~/chromium
git clone -b 158.0.8127.88 --depth=2 https://chromium.googlesource.com/chromium/src.git src
#   write ~/chromium/.gclient as build-chromium.ps1 does (src unmanaged, target_os = ["win"])
nice -n 19 ionice -c 2 -n 7 gclient sync --no-history --nohooks -D
nice -n 19 ionice -c 2 -n 7 gclient runhooks
mkdir -p src/out/Codecs && cp args.gn src/out/Codecs/ && cd src && gn gen out/Codecs
nice -n 19 ionice -c 2 -n 7 autoninja -C out/Codecs -j 4 chrome
#   then copy the files win-archive-rel.json names from out/Codecs to the PC's builds\custom-VERSION\chrome-win64
```

A hook may ask for a host package the server doesn't have. Unpack it without root the RUFFLE5 way: `apt download
<package>`, then `dpkg-deb -x <file>.deb ~/prefix`.

## Not tried here

This machine has no Windows, so `build-chromium.ps1` is checked for syntax only. The arguments, file list, version
requirements and the AC-3/E-AC-3 path were read in Chromium 158.0.8127.88's own source. The first real run is on
your PC. If it stops, the last lines say which command failed, and running it again carries on.
