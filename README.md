# zigbeam

Elixir on a Seeed XIAO ESP32-C6 via [AtomVM](https://www.atomvm.net/), with:

- **Erlang distribution** so a host BEAM can `Node.connect/1` to the board, over the USB-C port
  (AtomVM `serial_dist`, default), over UART1 pins, or over Wi-Fi + TCP (see `config/config.exs`)
- a **Zigbee 3.0 End Device** (Home Automation on/off light endpoint) driven from Elixir, through a
  custom AtomVM port driver wrapping Espressif's `esp-zigbee-lib` v2

Nothing in the AtomVM ecosystem provided Zigbee bindings (see AtomVM discussion #1968), so the
driver lives in `firmware/components/atomvm_zigbee/`.

## Layout

```
lib/zigbeam.ex           boot: transport (usb | uart | wifi) -> distribution -> Zigbeam.Server
config/config.exs        transport choice, UART pins (compile-time)
config/wifi.secret.exs   Wi-Fi credentials, git-ignored (see the .example file)
lib/zigbeam/server.ex    registered :zigbeam process; owns the Zigbee port, fans out events
lib/zigbeam/zigbee.ex    Elixir API for the port driver
firmware/                custom AtomVM firmware build for the C6 (see below)
scripts/host.exs         talk to the board from a host BEAM
```

## Toolchain (what this was built with)

- Elixir 1.18.4-otp-28 / Erlang 28.1 via mise (pinned in `.tool-versions`)
- AtomVM `release-0.7` branch (0.7.0-beta.1) checked out at `~/sprawl/_vendor/AtomVM`
- ESP-IDF v5.5.5 at `~/esp/esp-idf`, `espressif/esp-zigbee-lib` 2.0.4 from the component registry
- `gperf` from linuxbrew, `rebar3` in `~/.local/bin`, `esptool` 5.x

## Firmware

The board needs a custom AtomVM image: Elixir support, the Zigbee stack, a bigger app partition and
two Zigbee partitions. `firmware/partitions-zigbeam.csv` lays out the 4MB flash as

| partition  | offset   | size    |
|------------|----------|---------|
| factory    | 0x10000  | 2.4 MB  |
| boot.avm   | 0x280000 | 512 KB  |
| main.avm   | 0x300000 | 960 KB  |
| zb_storage | 0x3F0000 | 16 KB   |
| zb_fct     | 0x3F4000 | 1 KB    |

```
cd firmware
./build.sh            # host-side AtomVM libs, then idf.py build (first run: ~10 min)
./flash.sh            # bootloader + partition table + AtomVM + boot.avm  (/dev/ttyACM1)
./monitor.sh          # serial console
```

`build.sh` symlinks `components/atomvm_zigbee` into the AtomVM tree and applies two patches:
`0001-atomvm-allow-custom-partition-table.patch` (lets us pass our partition table to the AtomVM
CMake) and `0002-serial-dist-recover-stale-uart-reader.patch` (a `serial_dist` link manager that hit
`ealready` on the UART used to die, leaving the board silent on the serial link until reset).
`sdkconfig.zigbeam` turns on `CONFIG_ZB_ENABLED`/`CONFIG_ZB_ZED`, keeps Wi-Fi + 802.15.4 software
coexistence on, builds with `-Os`, enables the UART port driver (which also drives the USB
Serial/JTAG peripheral) and keeps the **log console on UART0 only** (XIAO D6 = TX, D7 = RX, 3.3 V),
because the USB port carries distribution. `monitor.sh` on the USB port therefore shows only ROM
and bootloader output; attach a USB-UART adapter to D6/D7 for AtomVM logs.

## Application

```
mix deps.get
mix atomvm.esp32.flash      # packs lib/ into zigbeam.avm and writes it to the main.avm partition
```

### Transport: USB serial (default)

With `transport: :usb` the board runs Erlang distribution over its USB-C port using AtomVM's
`serial_dist` (Paul Guyot's serial distribution carrier) on the ESP32-C6's USB Serial/JTAG
peripheral. The node is `zigbeam@serial.local`, cookie `zigbeam`, and it needs no Wi-Fi at all,
which also leaves the 2.4 GHz radio to Zigbee alone. The host side lives in
[`../zigbeam_host`](../zigbeam_host): a BEAM node with the matching `serial_dist` module and a
Circuits.UART backend, so a laptop, a Raspberry Pi or a Nerves device can `Node.connect/1` to the
board through `/dev/ttyACM0`.

```
cd ../zigbeam_host
ZIGBEAM_SERIAL=/dev/ttyACM1 bin/host
iex> ZigbeamHost.status()
iex> ZigbeamHost.set(true)
```

Measured on this laptop: connect in ~0.25 s (0.75 s after an unclean host exit), `erpc` round trip
~55 ms, a board reboot is noticed by the host's heartbeat within ~8 s and the link is back ~2 s later.

`transport: :uart` is the same thing over UART1 on D4 (GPIO22, TX) / D5 (GPIO23, RX) at
`uart_speed`, for a host wired to GPIO pins instead of USB. D6/D7 stay the log console.

### Transport: Wi-Fi

With `transport: :wifi` the board joins the configured network and runs TCP distribution plus its
own epmd. Credentials go in the git-ignored `config/wifi.secret.exs` (copy
`config/wifi.secret.exs.example`); the cookie is a module attribute in `lib/zigbeam.ex`.

On boot the board prints its node name, e.g. `zigbeam@192.168.3.70`. From the host:

```
elixir --name host@<host-ip> --cookie zigbeam scripts/host.exs 192.168.3.70         # status
elixir --name host@<host-ip> --cookie zigbeam scripts/host.exs 192.168.3.70 watch   # stream events
elixir --name host@<host-ip> --cookie zigbeam scripts/host.exs 192.168.3.70 on      # set on/off attr
```

or from `iex --name host@<host-ip> --cookie zigbeam`:

```elixir
Node.connect(:"zigbeam@192.168.3.70")
:erpc.call(:"zigbeam@192.168.3.70", :erlang, :node, [])
send({:zigbeam, :"zigbeam@192.168.3.70"}, {:subscribe, self()})
```

## Zigbee

The device starts as a factory-new End Device and immediately does network steering, so open your
network for joining (permit join in Zigbee2MQTT / ZHA / deCONZ) and it should show up as an on/off
light with manufacturer `Underjord`, model `zigbeam`. Once joined it rejoins on reboot by itself.

Events delivered to subscribers (and printed on the console):

```
{:zigbee, node, {:joined, pan_id: _, short_addr: _, channel: _, ext_pan_id: <<_::64>>}}
{:zigbee, node, {:attribute, endpoint, cluster_id, attribute_id, value}}   # e.g. {:attribute, 10, 6, 0, true}
{:zigbee, node, {:steering_failed, status}}
{:zigbee, node, :left}
{:zigbee, node, {:signal, type, status}}
```

Port protocol (`Zigbeam.Zigbee`): `start/1`, `status/1`, `join/1`, `leave/1`, `factory_reset/1`,
`set_attribute/4`, `close/1`. `set_attribute(port, 0x0006, 0x0000, true)` sets the on/off attribute
and sends a ZCL report to bound devices.

## Known limits

- The port exposes a single on/off light endpoint. Other device types mean adding another
  `ezb_zha_create_*` call in `zigbee_driver.c` (or a generic cluster list builder).
- Attribute values cross the boundary as bool / integer / binary; strings and arrays come back as raw
  binaries.
- Wi-Fi + Zigbee share one radio. Espressif rates STA + End Device coexistence as stable; expect some
  802.15.4 packet loss under heavy Wi-Fi traffic. The serial transports avoid this entirely.
- Serial distribution runs at 115200 baud; fine for control and events, slow for bulk data
  (~10 kB/s). AtomVM nodes show up as hidden nodes, so use `Node.list(:connected)`.
- With the console moved off USB, AtomVM's own log lines are only visible on D6/D7.
