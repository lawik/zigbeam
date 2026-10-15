import Config

# How the board clusters with the host. Baked in at compile time
# (Application.compile_env), so re-run `mix atomvm.esp32.flash` after changing.
#
#   :usb   serial distribution over the USB-C port (USB Serial/JTAG peripheral).
#          One cable to a Raspberry Pi gives power, distribution and flashing.
#          Needs the firmware console kept off USB (see firmware/sdkconfig.zigbeam).
#   :uart  serial distribution over UART1 on the pins below (3.3 V), e.g. to
#          a Pi's GPIO14/15. Console stays on UART0 (D6/D7).
#   :wifi  join Wi-Fi and run TCP distribution + epmd (the original setup).
#   :zigbee serial distribution over Zigbee APS frames to another zigbeam board
#          (plus the USB link); node name zb<MAC tail>@zigbee.local; runs the
#          ping-pong demo (Zigbeam.PingPong).
config :zigbeam,
  transport: :zigbee,
  uart_pins: [tx: 22, rx: 23],
  uart_speed: 115_200,
  wifi: [ssid: nil, psk: nil]

# Wi-Fi credentials live in a git-ignored file; see config/wifi.secret.exs.example.
if File.exists?(Path.join(__DIR__, "wifi.secret.exs")) do
  import_config "wifi.secret.exs"
end
