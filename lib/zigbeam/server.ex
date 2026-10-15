defmodule Zigbeam.Server do
  @moduledoc """
  Long-lived process registered as `:zigbeam` that owns the Zigbee port and
  fans events out to subscribers. From the host node:

      send({:zigbeam, :"zigbeam@192.168.x.y"}, {:subscribe, self()})
      send({:zigbeam, :"zigbeam@192.168.x.y"}, {:call, self(), ref, :status})
      receive do {^ref, reply} -> reply end
  """

  alias Zigbeam.Zigbee

  def run do
    Process.register(self(), :zigbeam)

    zb =
      case Zigbee.start(manufacturer: "Underjord", model: "zigbeam") do
        {:ok, port} ->
          IO.puts("zigbeam: zigbee stack started, steering...")
          port

        error ->
          IO.puts("zigbeam: zigbee start failed: #{inspect(error)}")
          nil
      end

    state = %{zb: zb, subscribers: [], last_event: nil, on: false, zb_info: nil, failed: nil, extra: []}
    show(state)
    loop(state)
  end

  defp loop(state) do
    receive do
      {:subscribe, pid} ->
        IO.puts("zigbeam: subscriber #{inspect(pid)}")
        subs = if pid in state.subscribers, do: state.subscribers, else: [pid | state.subscribers]
        loop(%{state | subscribers: subs})

      {:extra, lines} when is_list(lines) ->
        state = %{state | extra: lines}
        show(state)
        loop(state)

      {:unsubscribe, pid} ->
        loop(%{state | subscribers: List.delete(state.subscribers, pid)})

      {:call, from, ref, request} ->
        {reply, state} = handle_call(request, state)
        send(from, {ref, reply})
        show(state)
        loop(state)

      {:zigbee, event} ->
        IO.puts("zigbeam: zigbee #{inspect(event)}")
        Enum.each(state.subscribers, fn pid -> send(pid, {:zigbee, node(), event}) end)
        state = %{handle_event(event, state) | last_event: event}
        show(state)
        loop(state)

      other ->
        IO.puts("zigbeam: unexpected #{inspect(other)}")
        loop(state)
    end
  end

  # The coordinator toggled our on/off cluster (cluster 0x0006, attribute 0x0000).
  defp handle_event({:attribute, _ep, 0x0006, 0x0000, on}, state), do: %{state | on: on == true or on == 1}
  defp handle_event({:joined, info}, state), do: %{state | zb_info: info, failed: nil}
  defp handle_event({:steering_failed, status}, state), do: %{state | failed: status}
  defp handle_event(_event, state), do: state

  # --- OLED (XIAO expansion board) ---------------------------------------------

  defp show(state) do
    Zigbeam.Display.show([
      "zigbeam " <> Zigbeam.transport_label(),
      :erlang.atom_to_binary(node()),
      zb_line(state),
      pan_line(state),
      "light: " <> if(state.on, do: "ON", else: "off")
      | extra_lines(state)
    ])
  end

  defp extra_lines(%{extra: []} = state), do: ["", event_line(state)]
  defp extra_lines(%{extra: lines}), do: lines

  defp zb_line(%{zb: nil}), do: "zb: not started"
  defp zb_line(%{zb_info: info}) when is_list(info), do: "zb: joined ch " <> int(info[:channel])
  defp zb_line(%{failed: nil}), do: "zb: joining..."
  defp zb_line(%{failed: status}), do: "zb: join failed " <> int(status)

  defp pan_line(%{zb_info: info}) when is_list(info) do
    "pan " <> int(info[:pan_id]) <> " addr " <> :erlang.integer_to_binary(info[:short_addr], 16)
  end

  defp pan_line(_), do: "permit join on hub?"

  defp event_line(%{last_event: nil}), do: ""
  defp event_line(%{last_event: {:attribute, _ep, cl, at, v}}), do: "attr " <> int(cl) <> "/" <> int(at) <> "=" <> inspect(v)
  defp event_line(%{last_event: {:signal, id, st}}), do: "signal " <> int(id) <> " st " <> int(st)
  defp event_line(%{last_event: {tag, _}}), do: "event " <> :erlang.atom_to_binary(tag)
  defp event_line(_), do: "event"

  defp int(i) when is_integer(i), do: :erlang.integer_to_binary(i)
  defp int(other), do: inspect(other)

  defp handle_call(:status, state) do
    {%{node: node(), on: state.on, last_event: state.last_event, zigbee: zb(state, &Zigbee.status/1)}, state}
  end

  defp handle_call(:join, state), do: {zb(state, &Zigbee.join/1), state}
  defp handle_call(:leave, state), do: {zb(state, &Zigbee.leave/1), state}
  defp handle_call(:factory_reset, state), do: {zb(state, &Zigbee.factory_reset/1), state}

  defp handle_call({:set, on}, state) when is_boolean(on) do
    {zb(state, &Zigbee.set_attribute(&1, 0x0006, 0x0000, on)), %{state | on: on}}
  end

  defp handle_call({:set_attribute, cluster, attr, value}, state) do
    {zb(state, &Zigbee.set_attribute(&1, cluster, attr, value)), state}
  end

  defp handle_call(other, state), do: {{:error, {:unknown_request, other}}, state}

  defp zb(%{zb: nil}, _fun), do: {:error, :zigbee_not_started}
  defp zb(%{zb: port}, fun), do: fun.(port)
end
