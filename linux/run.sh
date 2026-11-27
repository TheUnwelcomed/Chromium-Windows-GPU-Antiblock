#!/bin/bash
# Start Chromium with the switches in flags.txt (and --ozone-platform=x11 on Wayland with NVIDIA's driver).
exec python3 -I "$(dirname "$0")/antiblock.py" run "$@"
