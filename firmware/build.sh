#!/usr/bin/env bash
# Build the AtomVM + Zigbee firmware for the XIAO ESP32-C6.
#
#   ./build.sh            # configure (first time) and build
#   ./build.sh --clean    # wipe the IDF build dir first
#
# Output: $ATOMVM_DIR/src/platforms/esp32/build/atomvm-esp32.bin (+ bootloader,
# partition table, boot.avm) — flash everything with ./flash.sh.
set -euo pipefail
. "$(dirname "$0")/env.sh"

ESP32_DIR="$ATOMVM_DIR/src/platforms/esp32"
CHIP=esp32c6

# 1. host-side AtomVM build: produces build/libs/esp32boot/elixir_esp32boot.avm
mkdir -p "$ATOMVM_DIR/build"
if [ ! -f "$ATOMVM_DIR/build/build.ninja" ]; then
  (cd "$ATOMVM_DIR/build" && cmake .. -G Ninja)
fi

# 2. make sure AtomVM accepts our partition table (idempotent patch)
if ! grep -q "Caller-provided partition table" "$ESP32_DIR/CMakeLists.txt"; then
  (cd "$ATOMVM_DIR" && git apply "$ZIGBEAM_FW_DIR/patches/0001-atomvm-allow-custom-partition-table.patch")
fi

# 2b. serial_dist: recover from a stale UART reader after a controller dies
#     (otherwise the board goes silent on the serial link until reset)
if ! grep -q "clear_stale_reader" "$ATOMVM_DIR/libs/estdlib/src/serial_dist.erl"; then
  (cd "$ATOMVM_DIR" && git apply "$ZIGBEAM_FW_DIR/patches/0002-serial-dist-recover-stale-uart-reader.patch")
fi

# 2c. net_kernel: link the setup process so a failed outgoing handshake does
#     not leave the node stuck as pending forever
if ! grep -q "SetupPid = ProtoDist:setup" "$ATOMVM_DIR/libs/estdlib/src/net_kernel.erl"; then
  (cd "$ATOMVM_DIR" && git apply "$ZIGBEAM_FW_DIR/patches/0003-net-kernel-link-setup-process.patch")
fi

# 2d. (re)build boot.avm: estdlib (incl. the patched serial_dist) + eavmlib + Elixir libs
(cd "$ATOMVM_DIR/build" && ninja elixir_esp32boot | tail -1)

# 3. drop our component + partition table into the AtomVM esp32 tree
ln -sfn "$ZIGBEAM_FW_DIR/components/atomvm_zigbee" "$ESP32_DIR/components/atomvm_zigbee"
cp "$ZIGBEAM_FW_DIR/partitions-zigbeam.csv" "$ESP32_DIR/partitions-zigbeam.csv"

cd "$ESP32_DIR"
if [ "${1:-}" = "--clean" ]; then
  rm -rf build sdkconfig
fi

export SDKCONFIG_DEFAULTS="sdkconfig.defaults;$ZIGBEAM_FW_DIR/sdkconfig.zigbeam"
CMAKE_ARGS="-DATOMVM_ELIXIR_SUPPORT=on -DAVM_PARTITION_TABLE_FILENAME=partitions-zigbeam.csv"
if [ ! -f sdkconfig ] || ! grep -q 'CONFIG_IDF_TARGET="'$CHIP'"' sdkconfig || ! grep -q "CONFIG_ZB_ENABLED=y" sdkconfig; then
  idf.py $CMAKE_ARGS set-target $CHIP
fi
idf.py $CMAKE_ARGS build
idf.py size | tail -5
