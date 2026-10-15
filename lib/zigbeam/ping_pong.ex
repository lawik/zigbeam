defmodule Zigbeam.PingPong do
  @moduledoc """
  Two boards pass an incrementing number back and forth over Erlang
  distribution (which here runs over Zigbee, see `Zigbeam.ZigbeeLink` and `zigbee_dist`).

  The board with the smaller node name serves first; sending to
  `{:pingpong, peer}` auto-connects. Whoever holds the ball shows it on the
  display, waits a moment and sends it back incremented. If the ball is lost
  (link down, peer reboot) the server re-serves the last number it saw.
  """

  @hold_ms 500
  @watchdog_ms 10_000

  def run(name) do
    Process.register(self(), :pingpong)
    :erlang.send_after(@watchdog_ms, self(), :watchdog)
    extra(["peer: searching...", "", ""])
    loop(%{name: name, n: 0, last_from: nil, last_rx: 0, serving: false})
  end

  defp loop(state) do
    receive do
      {:ball, n, from} ->
        IO.puts("pingpong: ball #{n} from #{from}")
        extra(["peer: " <> short(from), "ball " <> int(n) <> " <- " <> short(from), connected_line()])
        :erlang.send_after(@hold_ms, self(), {:return, n + 1, from})
        loop(%{state | n: n, last_from: from, last_rx: now()})

      {:return, n, to} ->
        send({:pingpong, to}, {:ball, n, node()})
        extra(["peer: " <> short(to), "ball " <> int(n) <> " -> " <> short(to), connected_line()])
        loop(%{state | n: n})

      :watchdog ->
        :erlang.send_after(@watchdog_ms, self(), :watchdog)
        loop(maybe_serve(state))

      other ->
        IO.puts("pingpong: ignoring #{inspect(other)}")
        loop(state)
    end
  end

  # No ball seen for a while: the initiator (smaller node name) serves.
  defp maybe_serve(state) do
    case Zigbeam.ZigbeeLink.peer() do
      {_addr, peer_name} when is_binary(peer_name) ->
        peer = :erlang.binary_to_atom(peer_name, :utf8)
        initiator? = :erlang.atom_to_binary(state.name) < peer_name
        idle? = now() - state.last_rx > @watchdog_ms

        if initiator? and idle? do
          IO.puts("pingpong: serving #{state.n} to #{peer}")
          extra(["peer: " <> short(peer), "serving " <> int(state.n) <> "...", connected_line()])
          send({:pingpong, peer}, {:ball, state.n, node()})
        else
          extra(["peer: " <> short(peer), "ball " <> int(state.n), connected_line()])
        end

        state

      nil ->
        extra(["peer: searching...", "", connected_line()])
        state

      other ->
        IO.puts("pingpong: link not answering: #{inspect(other)}")
        state
    end
  end

  defp extra(lines) do
    case Process.whereis(:zigbeam) do
      nil -> :ok
      pid -> send(pid, {:extra, lines})
    end
  end

  # erlang:nodes/1 does not exist on AtomVM; show link health from the ball instead.
  defp connected_line, do: "node " <> short(node())

  defp short(node) when is_atom(node), do: short(:erlang.atom_to_binary(node))

  defp short(name) when is_binary(name) do
    case :binary.split(name, "@") do
      [n, _] -> n
      _ -> name
    end
  end

  defp int(i), do: :erlang.integer_to_binary(i)
  defp now, do: :erlang.monotonic_time(:millisecond)
end
