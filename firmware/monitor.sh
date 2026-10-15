#!/usr/bin/env bash
# Serial console (resets the board first). Ctrl-] to quit.
set -euo pipefail
. "$(dirname "$0")/env.sh"
PORT="${1:-/dev/ttyACM1}"
cd "$ATOMVM_DIR/src/platforms/esp32"
idf.py -p "$PORT" monitor
