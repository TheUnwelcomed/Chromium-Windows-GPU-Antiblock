#!/bin/bash
# Ask Chromium what it does with the graphics card: ok / FAIL / -- lines, the full report in reports/.
#   ./check.sh keep                       leave the window open afterwards
#   ./check.sh --use-angle=vulkan         try a switch once without putting it in flags.txt
exec python3 -I "$(dirname "$0")/antiblock.py" check "$@"
