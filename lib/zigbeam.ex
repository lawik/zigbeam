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
    Zigbeam.Display.start()
    Zigbeam.Display.show(["zigbeam " <> transport_label(), "booting..."])
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
  defp boot(:zigbee), do: boot_zigbee()

  @doc "Short label of the compiled-in transport, for the display."
  def transport_label, do: Atom.to_string(@transport)

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

  # --- distribution over Zigbee (plus USB for debugging) ----------------------
  #
  # Boot: Zigbee stack -> node name from the IEEE address -> Zigbeam.ZigbeeLink
  # (peer discovery + APS packet transport) -> net_kernel with zigbee_dist ->
  # Zigbeam.PingPong. See src/zigbee_dist.erl.

  # Node name from the IEEE address: "zb" + last two bytes of the MAC. The
  # stack hands the address out little-endian, so those are the first two bytes.
  defp zigbee_node_name(<<a, b, _::binary>>) do
    hex = :erlang.integer_to_binary(a * 256 + b, 16)
    :erlang.binary_to_atom("zb" <> hex <> "@zigbee.local", :utf8)
  end

  defp boot_zigbee do
    spawn(fn -> boot_log_loop([]) end) |> Process.register(:zigbeam_boot_log)
    _server = spawn(fn -> Zigbeam.Server.run() end)

    try do
      zb = wait_for_stack()
      name = zigbee_node_name(zb[:ieee_addr])
      log("name " <> :erlang.atom_to_binary(name))
      port = Process.whereis(:zigbee)

      {:ok, _} = Zigbeam.ZigbeeLink.start(port, name)
      log("zigbee link up")

      # zigbee_dist carries *@zigbee.local nodes over APS frames. Passing
      # uart_opts here would add a serial_dist link too, but the USB port now
      # carries the console (firmware/sdkconfig.zigbeam), so it stays out.
      {:ok, _} =
        :net_kernel.start(name, %{
          name_domain: :longnames,
          proto_dist: :zigbee_dist,
          avm_dist_opts: %{}
        })

      :net_kernel.set_cookie(@cookie)
      log("dist up " <> :erlang.atom_to_binary(node()))
      supervise_ping_pong(name)
    catch
      kind, reason ->
        log("boot crashed: " <> inspect({kind, reason}))
        IO.puts("zigbeam: boot crash " <> inspect({kind, reason, __STACKTRACE__}))
        send(:zigbeam, {:extra, ["BOOT CRASHED", inspect(reason), ""]})
        :timer.sleep(:infinity)
    end
  end

  # Keep the demo alive: run Zigbeam.PingPong in its own process and restart
  # it (with the reason on the console and the display) if it crashes.
  defp supervise_ping_pong(name) do
    pid = spawn(fn -> Zigbeam.PingPong.run(name) end)
    ref = :erlang.monitor(:process, pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} ->
        IO.puts("zigbeam: pingpong died: " <> inspect(reason))
        log("pingpong died: " <> inspect(reason))
        send(:zigbeam, {:extra, ["pingpong crashed", inspect(reason), "restarting"]})
        :timer.sleep(2_000)
        supervise_ping_pong(name)
    end
  end

  # Zigbee stack started (ieee_addr known); joining can finish later.
  defp wait_for_stack do
    :timer.sleep(500)

    case Process.whereis(:zigbeam) do
      nil ->
        wait_for_stack()

      server ->
        ref = :erlang.make_ref()
        send(server, {:call, self(), ref, :status})

        receive do
          {^ref, %{zigbee: zb}} when is_list(zb) ->
            if zb[:started] and is_binary(zb[:ieee_addr]), do: zb, else: wait_for_stack()

          {^ref, _} ->
            wait_for_stack()
        after
          5_000 -> wait_for_stack()
        end
    end
  end

  @doc "Boot steps so far (oldest first); readable over erpc when the console is not."
  def boot_log do
    ref = :erlang.make_ref()
    send(:zigbeam_boot_log, {:get, self(), ref})

    receive do
      {^ref, log} -> log
    after
      1_000 -> {:error, :timeout}
    end
  end

  defp log(step) do
    IO.puts("zigbeam: " <> step)
    send(:zigbeam_boot_log, {:log, step})
    send(:zigbeam, {:extra, ["boot: " <> step, "", ""]})
  end

  defp boot_log_loop(log) do
    receive do
      {:log, step} -> boot_log_loop(log ++ [step])
      {:get, from, ref} -> send(from, {ref, log}); boot_log_loop(log)
    end
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
