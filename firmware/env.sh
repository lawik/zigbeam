# Source this to get the toolchain used to build the zigbeam firmware.
export IDF_PATH="${IDF_PATH:-$HOME/esp/esp-idf}"
export ATOMVM_DIR="${ATOMVM_DIR:-$HOME/sprawl/_vendor/AtomVM}"
export ZIGBEAM_FW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# gperf comes from linuxbrew; erlc/elixir from mise (pinned in ../.tool-versions).
export PATH="/home/linuxbrew/.linuxbrew/bin:$HOME/.local/share/mise/installs/erlang/28.1/bin:$HOME/.local/share/mise/installs/elixir/1.18.4-otp-28/bin:$HOME/.local/bin:$PATH"
. "$IDF_PATH/export.sh" > /dev/null
