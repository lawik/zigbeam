# Connect from a host BEAM to the board, subscribe to Zigbee events and run a
# few calls. Usage (host IP must be on the same LAN as the board):
#
#   elixir --name host@192.168.3.76 --cookie zigbeam scripts/host.exs 192.168.3.70
#   elixir --name host@192.168.3.76 --cookie zigbeam scripts/host.exs 192.168.3.70 on
#   elixir --name host@192.168.3.76 --cookie zigbeam scripts/host.exs 192.168.3.70 off
#   elixir --name host@192.168.3.76 --cookie zigbeam scripts/host.exs 192.168.3.70 join
#   elixir --name host@192.168.3.76 --cookie zigbeam scripts/host.exs 192.168.3.70 leave
#   elixir --name host@192.168.3.76 --cookie zigbeam scripts/host.exs 192.168.3.70 factory_reset
#   elixir --name host@192.168.3.76 --cookie zigbeam scripts/host.exs 192.168.3.70 watch
#
# The board's node name is zigbeam@<its ip>; it is printed on its serial console.

[ip | rest] = System.argv()
target = :"zigbeam@#{ip}"

true = Node.connect(target) || raise "could not connect to #{target}"
IO.puts("connected to #{target}")

call = fn request ->
  ref = make_ref()
  send({:zigbeam, target}, {:call, self(), ref, request})

  receive do
    {^ref, reply} -> reply
  after
    10_000 -> {:error, :timeout}
  end
end

case rest do
  [] ->
    IO.inspect(call.(:status), label: "status")

  ["on"] ->
    IO.inspect(call.({:set, true}), label: "set on")

  ["off"] ->
    IO.inspect(call.({:set, false}), label: "set off")

  ["join"] ->
    IO.inspect(call.(:join), label: "join")

  ["leave"] ->
    IO.inspect(call.(:leave), label: "leave")

  ["factory_reset"] ->
    IO.inspect(call.(:factory_reset), label: "factory_reset")

  ["watch"] ->
    send({:zigbeam, target}, {:subscribe, self()})
    IO.inspect(call.(:status), label: "status")
    IO.puts("watching for zigbee events, ctrl-c to stop")

    Stream.repeatedly(fn ->
      receive do
        {:zigbee, node, event} -> IO.inspect(event, label: "#{node}")
      end
    end)
    |> Stream.run()

  ["rpc", m, f] ->
    IO.inspect(:erpc.call(target, String.to_atom(m), String.to_atom(f), [], 10_000), label: "#{m}.#{f}")
end
