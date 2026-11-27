# Notice

This repository started from [scheib/chromium-latest-linux](https://github.com/scheib/chromium-latest-linux)
(commit `4f4e9b8`), Copyright its authors, licensed under the Apache License 2.0 (the [LICENSE](LICENSE) file is that
repository's own). Its four files were `update.sh`, `run.sh`, `update-and-run.sh` and a one-line README.

Changed from it (Apache-2.0, section 4b):

- **What is fetched.** Chrome for Testing (a channel, a milestone or an exact version) in place of the newest raw
  Chromium snapshot. Snapshots are built without the proprietary codecs (no H.264, AAC or HEVC), so they are no longer
  fetched at all.
- **How it is fetched.** Every download is checked against Google's own record of the file (size and MD5) before it is
  unpacked. A failed download no longer leaves a broken `latest`. Old builds are pruned to the current one and the one
  before it. On Linux, permissions survive unpacking.
- **How it is run.** Switches come from `flags.txt` (no GPU blocklist, no quiet fallback to software, the
  high-performance adapter), plus what the machine needs (X11 on Wayland with NVIDIA's driver). Arguments are passed
  quoted. The browser's output goes to a log instead of `/dev/null`.
- **New.** A Windows version (`antiblock.ps1` and the `.cmd` files). A check of what the browser does with the
  graphics card and the codecs (`check/`). Tests (`tests/`).

Everything new is under the same licence.
