defmodule Zigbeam do
  @moduledoc """
  Entry point for the XIAO ESP32-C6 node running on AtomVM.

  Boot sequence:

    1. Bring up a transport to the host (see `config/config.exs`): serial
       distribution over USB or UART1, or Wi-Fi + TCP distribution.
    2. Start Erlang distribution so the host BEAM can `Node.connect/1` to us.
    3. Bring up the Zigbee end device and ask it to join the local network.
    4. Sit in a supervision-ish loop forwarding Zigbee events to any
       subscribers (local or remote).
  """

  @compile {:no_warn_undefined, [:network, :epmd, :net_kernel, :esp]}

  @transport Application.compile_env(:zigbeam, :transport, :usb)
  @uart_pins Application.compile_env(:zigbeam, :uart_pins, tx: 22, rx: 23)
  @uart_speed Application.compile_env(:zigbeam, :uart_speed, 115_200)
  @wifi Application.compile_env(:zigbeam, :wifi, ssid: nil, psk: nil)
  @cookie "zigbeam"
  @serial_node :"zigbeam@serial.local"

  def start do
    IO.puts("zigbeam: booting, transport #{@transport}")
    boot(@transport)
  end

  # --- serial distribution (USB Serial/JTAG or UART1) ------------------------

  defp boot(:usb), do: boot_serial(peripheral: ~c"USB_SERIAL_JTAG")

  defp boot(:uart) do
    boot_serial(
      peripheral: ~c"UART1",
      speed: @uart_speed,
      tx: Keyword.fetch!(@uart_pins, :tx),
      rx: Keyword.fetch!(@uart_pins, :rx)
    )
  end

  defp boot(:wifi), do: boot_wifi()

  defp boot_serial(uart_opts) do
    {:ok, _} =
      :net_kernel.start(@serial_node, %{
        name_domain: :longnames,
        proto_dist: :serial_dist,
        avm_dist_opts: %{uart_opts: uart_opts, uart_module: :uart}
      })

    :net_kernel.set_cookie(@cookie)
    IO.puts("zigbeam: serial distribution up as #{@serial_node} on #{uart_opts[:peripheral]}")
    Zigbeam.Server.run()
  end

  # --- Wi-Fi + TCP distribution -----------------------------------------------

  defp boot_wifi do
    if is_nil(@wifi[:ssid]) do
      IO.puts("zigbeam: transport is :wifi but no credentials; see config/wifi.secret.exs.example")
      Zigbeam.Server.run()
    else
      connect_wifi()
    end
  end

  defp connect_wifi do
    case :network.wait_for_sta([ssid: @wifi[:ssid], psk: @wifi[:psk]], 30_000) do
      {:ok, {ip, _netmask, _gateway}} ->
        IO.puts("zigbeam: wifi up, ip #{format_ip(ip)}")
        start_tcp_distribution(ip)
        Zigbeam.Server.run()

      error ->
        IO.puts("zigbeam: wifi failed: #{inspect(error)}")
        wifi_retry()
    end
  end

  # A soft reset (USB/JTAG, esp_restart) does not fully reset the C6 radio, and
  # once the 802.15.4 stack has run the Wi-Fi driver can fail to find any AP
  # after such a reset. Deep sleep powers the RF domain down, so the first
  # retry after a non-deep-sleep boot goes through a short deep sleep.
  defp wifi_retry do
    if :esp.reset_reason() == :esp_rst_deepsleep do
      # wait_for_sta leaves the network driver running; tear it down so the
      # next attempt can start it again.
      :network.stop()
      :timer.sleep(3_000)
      connect_wifi()
    else
      IO.puts("zigbeam: deep sleeping 500ms to power-cycle the radio")
      :esp.deep_sleep(500)
    end
  end

  defp start_tcp_distribution(ip) do
    {:ok, _epmd} = :epmd.start_link([])
    node_name = String.to_atom("zigbeam@" <> format_ip(ip))
    {:ok, _} = :net_kernel.start(node_name, %{name_domain: :longnames})
    :net_kernel.set_cookie(@cookie)
    IO.puts("zigbeam: distribution up as #{node_name} (cookie #{@cookie})")
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
end
