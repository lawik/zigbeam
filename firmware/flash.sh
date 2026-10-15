#!/usr/bin/env bash
# Flash bootloader + partition table + AtomVM app, then the Elixir boot library
# into the boot.avm partition. The application itself is flashed separately
# with `mix atomvm.esp32.flash`.
set -euo pipefail
. "$(dirname "$0")/env.sh"
PORT="${1:-/dev/ttyACM1}"
BOOT_AVM="$ATOMVM_DIR/build/libs/esp32boot/elixir_esp32boot.avm"
BOOT_OFFSET="$(awk -F, '/^boot\.avm/ { gsub(/ /, "", $4); print $4 }' "$ZIGBEAM_FW_DIR/partitions-zigbeam.csv")"

cd "$ATOMVM_DIR/src/platforms/esp32"
idf.py -p "$PORT" -b 921600 flash
# AtomVM's CMake only auto-flashes boot.avm for its stock partition layouts.
esptool --chip esp32c6 -p "$PORT" -b 921600 write-flash "$BOOT_OFFSET" "$BOOT_AVM"
