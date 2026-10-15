defmodule Zigbeam.ZigbeeLink do
  @moduledoc """
  Packet transport between zigbeam boards over raw Zigbee APS unicasts, used
  by the `zigbee_dist` distribution module.

  One process (registered `:zigbee_link`) owns the APS subscription and:

    * finds peers: broadcasts a hello with our node name until someone
      answers, answers hellos from others (type 1 hello, type 2 hello-ack);
    * sends packets: a packet up to `frame` bytes goes as one APS frame
      (type 0); bigger ones are split in fragments (type 3 = more, 4 = last).
      Each APS frame waits for its confirm (APS ack + retries) so order is
      kept and loss is detected;
    * delivers packets: `{:zigbee_packet, src_short, packet}` to the process
      routed for that source, or to the acceptor when there is none.

  Wire format per APS frame: `<<type, seq, payload::binary>>`. `seq` is a
  per-destination counter; a frame with the same seq as the previous one from
  that source is a duplicate (APS ack lost, sender retried) and is dropped.
  """

  alias Zigbeam.Zigbee

  @name :zigbee_link
  @frame 120
  @hello_interval 3_000
  # APS does its own retries (about 1.6 s apart, 3 tries) before a confirm
  # with an error status, so a confirm can legitimately take several seconds.
  @confirm_timeout 15_000
  @send_attempts 3
  @broadcast 0xFFFF

  # --- API --------------------------------------------------------------------

  def start(port, node_name) do
    parent = self()
    pid = spawn(fn -> init(port, node_name, parent) end)

    receive do
      {:zigbee_link_up, ^pid} -> {:ok, pid}
    after
      5_000 -> {:error, :timeout}
    end
  end

  @doc "`{short_addr, node_name_binary}` of the first known peer, or nil."
  def peer, do: call(:peer)

  @doc "All known peers as `%{short_addr => node_name_binary}`."
  def peers, do: call(:peers)

  @doc "Short address of the peer with this node name (atom or binary), or nil."
  def lookup(node) when is_atom(node), do: lookup(:erlang.atom_to_binary(node))
  def lookup(name) when is_binary(name), do: call({:lookup, name})

  @doc "Deliver packets from `src` to `pid` (a dist controller) until it dies."
  def route(src, pid), do: call({:route, src, pid})

  @doc "Process receiving packets from sources without a route (the dist acceptor)."
  def acceptor(pid), do: call({:acceptor, pid})

  @doc "Send one packet (binary) to a peer short address."
  def send_packet(dst, packet) when is_binary(packet), do: call({:send, dst, packet}, 30_000)

  defp call(request, timeout \\ 5_000) do
    ref = :erlang.make_ref()
    send(@name, {:call, self(), ref, request})

    receive do
      {^ref, reply} -> reply
    after
      timeout -> {:error, :timeout}
    end
  end

  # --- process ----------------------------------------------------------------

  defp init(port, node_name, parent) do
    Process.register(self(), @name)
    :ok = Zigbee.aps_subscribe(port, self())
    send(parent, {:zigbee_link_up, self()})
    send(self(), :hello_tick)

    loop(%{
      port: port,
      name: :erlang.atom_to_binary(node_name),
      peers: %{},
      routes: %{},
      acceptor: nil,
      rx: %{},
      tx_seq: %{},
      rx_seq: %{}
    })
  end

  defp loop(state) do
    receive do
      msg -> loop(handle(msg, state))
    end
  end

  defp handle({:call, from, ref, request}, state) do
    {reply, state} = handle_call(request, state)
    send(from, {ref, reply})
    state
  end

  defp handle({:zigbee, {:aps_data, src, <<type, seq, body::binary>>}}, state) when type in [0, 3, 4] do
    if Map.get(state.rx_seq, src) == seq do
      IO.puts("zigbee_link: duplicate frame #{seq} from #{src} dropped")
      state
    else
      stream_frame(type, src, body, %{state | rx_seq: Map.put(state.rx_seq, src, seq)})
    end
  end

  # A broadcast hello means the sender has no peers, i.e. it (re)started: any
  # connection we still hold to it is dead.
  defp handle({:zigbee, {:aps_data, src, <<1, _seq, name::binary>>}}, state) do
    state = drop_route(src, :peer_restarted, state)
    state = learn_peer(src, name, state)
    {_, state} = send_frame(src, <<2>>, state.name, state)
    state
  end

  defp handle({:zigbee, {:aps_data, src, <<2, _seq, name::binary>>}}, state) do
    learn_peer(src, name, state)
  end

  # confirms are consumed inside send_frame; a stray one lands here
  defp handle({:zigbee, {:aps_confirm, _dst, _status}}, state), do: state

  defp handle(:hello_tick, state) do
    {interval, state} =
      if map_size(state.peers) == 0 do
        {_, state} = send_frame(@broadcast, <<1>>, state.name, state)
        {@hello_interval, state}
      else
        {10 * @hello_interval, state}
      end

    :erlang.send_after(interval, self(), :hello_tick)
    state
  end

  defp handle({:DOWN, _ref, :process, pid, reason}, state) do
    routes =
      state.routes
      |> Map.to_list()
      |> Enum.filter(fn {_src, p} -> p != pid end)
      |> Map.new()

    if state.acceptor == pid do
      IO.puts("zigbee_link: acceptor down: #{inspect(reason)}")
      %{state | routes: routes, acceptor: nil}
    else
      %{state | routes: routes}
    end
  end

  defp handle(other, state) do
    IO.puts("zigbee_link: ignoring #{inspect(other)}")
    state
  end

  defp handle_call(:peer, state) do
    reply =
      case Map.to_list(state.peers) do
        [{src, name} | _] -> {src, name}
        [] -> nil
      end

    {reply, state}
  end

  defp handle_call(:peers, state), do: {state.peers, state}

  defp handle_call({:lookup, name}, state) do
    reply =
      Enum.find_value(Map.to_list(state.peers), fn
        {src, ^name} -> src
        _ -> nil
      end)

    {reply, state}
  end

  defp handle_call({:route, src, pid}, state) do
    :erlang.monitor(:process, pid)
    {:ok, %{state | routes: Map.put(state.routes, src, pid)}}
  end

  defp handle_call({:acceptor, pid}, state) do
    :erlang.monitor(:process, pid)
    {:ok, %{state | acceptor: pid}}
  end

  defp handle_call({:send, dst, packet}, state) do
    {result, state} = send_packet_frames(dst, packet, state)
    if result != :ok, do: IO.puts("zigbee_link: send to #{dst} failed: #{inspect(result)}")
    {result, state}
  end

  defp handle_call(other, state), do: {{:error, {:bad_request, other}}, state}

  defp stream_frame(0, src, packet, state), do: deliver(src, packet, state)

  defp stream_frame(3, src, part, state) do
    %{state | rx: Map.put(state.rx, src, [Map.get(state.rx, src, []), part])}
  end

  defp stream_frame(4, src, part, state) do
    packet = :erlang.iolist_to_binary([Map.get(state.rx, src, []), part])
    deliver(src, packet, %{state | rx: Map.delete(state.rx, src)})
  end

  defp drop_route(src, reason, state) do
    case Map.get(state.routes, src) do
      nil ->
        state

      pid ->
        IO.puts("zigbee_link: dropping connection to #{src}: #{inspect(reason)}")
        send(pid, {:zigbee_link_down, reason})
        %{state | routes: Map.delete(state.routes, src), rx: Map.delete(state.rx, src)}
    end
  end

  defp deliver(src, packet, state) do
    case Map.get(state.routes, src, state.acceptor) do
      nil -> IO.puts("zigbee_link: dropping packet from #{src}, nobody listening")
      pid -> send(pid, {:zigbee_packet, src, packet})
    end

    state
  end

  defp learn_peer(src, name, state) do
    case Map.get(state.peers, src) do
      ^name ->
        state

      _ ->
        IO.puts("zigbee_link: peer #{name} at #{src}")
        # the same node may come back with a new short address: drop the old entry
        peers = state.peers |> Enum.reject(fn {_s, n} -> n == name end) |> Map.new()
        %{state | peers: Map.put(peers, src, name)}
    end
  end

  defp send_packet_frames(dst, packet, state) when byte_size(packet) <= @frame do
    send_frame(dst, <<0>>, packet, state)
  end

  defp send_packet_frames(dst, packet, state) do
    <<part::binary-size(@frame), rest::binary>> = packet

    case send_frame(dst, <<3>>, part, state) do
      {:ok, state} when byte_size(rest) <= @frame -> send_frame(dst, <<4>>, rest, state)
      {:ok, state} -> send_packet_frames(dst, rest, state)
      error -> error
    end
  end

  # One APS request, then wait for its confirm so frames stay ordered. A
  # confirm with an error status means APS gave up after its own retries;
  # then we try again (the receiver drops duplicates by seq). No confirm at
  # all within the timeout counts as a dead link.
  defp send_frame(dst, type, body, state) do
    seq = Map.get(state.tx_seq, dst, 0)
    state = %{state | tx_seq: Map.put(state.tx_seq, dst, rem(seq + 1, 256))}
    {send_attempt(state.port, dst, <<type::binary, seq, body::binary>>, @send_attempts), state}
  end

  defp send_attempt(_port, _dst, _frame, 0), do: {:error, :aps_send_failed}

  defp send_attempt(port, dst, frame, attempts) do
    case Zigbee.aps_send(port, dst, frame) do
      :ok ->
        receive do
          {:zigbee, {:aps_confirm, ^dst, 0}} ->
            :ok

          {:zigbee, {:aps_confirm, ^dst, status}} ->
            IO.puts("zigbee_link: confirm status #{status} to #{dst}, retrying")
            send_attempt(port, dst, frame, attempts - 1)
        after
          @confirm_timeout ->
            IO.puts("zigbee_link: no confirm from #{dst} in #{@confirm_timeout} ms")
            {:error, :no_confirm}
        end

      {:error, reason} ->
        IO.puts("zigbee_link: aps_send failed: #{inspect(reason)}")
        :timer.sleep(100)
        send_attempt(port, dst, frame, attempts - 1)
    end
  end
end
