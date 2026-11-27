#!/bin/bash
# Fetch Chrome for Testing (built with H.264, AAC and HEVC): stable unless told otherwise (canary, beta, dev, 153, 153.0.8010.52).
exec python3 -I "$(dirname "$0")/antiblock.py" update "$@"
