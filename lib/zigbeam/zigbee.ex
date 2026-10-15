defmodule Zigbeam.Zigbee do
  @moduledoc """
  Elixir side of the `zigbee` AtomVM port driver (see
  `firmware/components/atomvm_zigbee/`).

  The driver wraps Espressif's esp-zigbee-lib and exposes the device as a
  Zigbee 3.0 End Device with a Home Automation on/off light endpoint, so it
  shows up in Zigbee2MQTT / ZHA / deCONZ as a switchable light. Attribute
  writes coming from the coordinator (for example on/off commands) are
  forwarded to the process that called `start/1` as

      {:zigbee, {:attribute, endpoint, cluster_id, attribute_id, value}}

  Network lifecycle events arrive as

      {:zigbee, {:joined, %{pan_id: _, short_addr: _, channel: _, ext_pan_id: _}}}
      {:zigbee, {:steering_failed, status}}
      {:zigbee, :left}
      {:zigbee, {:signal, signal_id, status}}   # anything else, for debugging

  All calls go through `:port.call/3`, which is synchronous with a timeout.
  """

  @compile {:no_warn_undefined, [:port]}

  @timeout 10_000

  @type port_ref :: port()

  @doc """
  Open the driver, start the Zigbee stack as an End Device and begin
  network steering. The calling process receives events.

  Options:

    * `:endpoint` - endpoint id, default 10
    * `:channel_mask` - bitmask of 802.15.4 channels to scan, default all (11-26)
    * `:auto_join` - start steering immediately, default true
    * `:manufacturer` / `:model` - strings for the Basic cluster
  """
  @spec start(keyword()) :: {:ok, port_ref()} | {:error, term()}
  def start(opts \\ []) do
    case open_driver() do
      {:ok, port} ->
        case :port.call(port, {:start, opts}, @timeout) do
          :ok -> {:ok, port}
          error -> error
        end

      error ->
        error
    end
  end

  defp open_driver do
    try do
      case :erlang.open_port({:spawn, "zigbee"}, []) do
        port when is_port(port) -> {:ok, port}
        other -> {:error, {:no_zigbee_driver, other}}
      end
    catch
      kind, reason -> {:error, {:no_zigbee_driver, kind, reason}}
    end
  end

  @doc "Current stack state as a map."
  @spec status(port_ref()) :: map() | {:error, term()}
  def status(port), do: :port.call(port, :status, @timeout)

  @doc "Start (or restart) network steering, i.e. try to join an open network."
  @spec join(port_ref()) :: :ok | {:error, term()}
  def join(port), do: :port.call(port, :join, @timeout)

  @doc "Leave the current network."
  @spec leave(port_ref()) :: :ok | {:error, term()}
  def leave(port), do: :port.call(port, :leave, @timeout)

  @doc "Wipe Zigbee persistent storage and reboot the stack."
  @spec factory_reset(port_ref()) :: :ok | {:error, term()}
  def factory_reset(port), do: :port.call(port, :factory_reset, @timeout)

  @doc """
  Write a local ZCL attribute and report it to bound devices / the coordinator.

  `value` is an integer or boolean; the driver picks the ZCL encoding from the
  attribute definition. Example, flip our on/off state:

      Zigbeam.Zigbee.set_attribute(port, 0x0006, 0x0000, true)
  """
  @spec set_attribute(port_ref(), non_neg_integer(), non_neg_integer(), integer() | boolean()) ::
          :ok | {:error, term()}
  def set_attribute(port, cluster_id, attribute_id, value) do
    :port.call(port, {:set_attribute, cluster_id, attribute_id, value}, @timeout)
  end

  @doc "Close the port. The stack keeps running; this just drops the Erlang handle."
  @spec close(port_ref()) :: :ok
  def close(port), do: :port.call(port, :close, @timeout)

  @doc "Route `{:zigbee, {:aps_data, src, bin}}` and `{:zigbee, {:aps_confirm, dst, status}}` to `pid`."
  def aps_subscribe(port, pid), do: :port.call(port, {:aps_subscribe, pid}, @timeout)

  @doc "Send up to 128 bytes as a raw APS unicast (short address; 0xFFFF broadcasts) on the zigbeam cluster."
  def aps_send(port, dst_short, data) when is_binary(data), do: :port.call(port, {:aps_send, dst_short, data}, @timeout)
end
