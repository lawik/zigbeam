%% Erlang distribution over Zigbee APS frames, for AtomVM on the zigbeam
%% boards. Packet oriented: every distribution packet (handshake messages,
%% data, ticks) travels as one APS unicast on the zigbeam cluster, split in
%% fragments by Zigbeam.ZigbeeLink when needed. No extra framing, no CRC: the
%% MAC layer already checks frames and APS acks/retries each one.
%%
%% The USB serial link is kept as a second transport by delegating to
%% serial_dist (one proto_dist module per node is all net_kernel allows):
%% nodes named *@zigbee.local go over Zigbee, everything else over serial.
%%
%% Peers are found by the link's hello broadcasts; `setup/5' needs the peer's
%% node name to be known already (Zigbeam.ZigbeeLink:lookup/1).
-module(zigbee_dist).

-include_lib("kernel/include/net_address.hrl").
-include_lib("kernel/include/dist.hrl").
-include_lib("kernel/include/dist_util.hrl").

-export([
    listen/1, listen/2,
    address/0,
    accept/1,
    accept_connection/5,
    setup/5,
    close/1,
    select/1,
    is_node_name/1
]).

-define(LINK, zigbee_link).
-define(ACCEPTOR, zigbee_dist_acceptor).

listen(Name) ->
    listen(Name, #{}).

%% Opts may carry serial_dist's uart_opts/uart_ports/uart_module; when present
%% the USB link is opened too.
listen(Name, Opts) when is_map(Opts) ->
    case whereis(?LINK) of
        undefined ->
            {error, zigbee_link_not_running};
        _Link ->
            Serial =
                case maps:is_key(uart_opts, Opts) orelse maps:is_key(uart_ports, Opts) of
                    true ->
                        case serial_dist:listen(Name, Opts) of
                            {ok, {SerialHandle, _Addr, _Creation}} ->
                                SerialHandle;
                            Error ->
                                io:format("zigbee_dist: serial listen failed: ~p~n", [Error]),
                                none
                        end;
                    false ->
                        none
                end,
            {ok, {{zigbee, Serial}, address(), 1}}
    end.

address() ->
    #net_address{address = zigbee, host = zigbee, protocol = zigbee, family = zigbee}.

%% Called by net_kernel (in its own process). Starts the Zigbee acceptor and,
%% when a serial handle is present, serial_dist's own acceptor (which reports
%% to self(), i.e. the kernel, by itself).
accept({zigbee, Serial}) ->
    Kernel = self(),
    case Serial of
        none -> ok;
        _ -> serial_dist:accept(Serial)
    end,
    Acceptor = spawn_link(fun() -> acceptor_init(Kernel) end),
    Acceptor.

acceptor_init(Kernel) ->
    register(?ACCEPTOR, self()),
    'Elixir.Zigbeam.ZigbeeLink':acceptor(self()),
    acceptor_loop(Kernel).

%% A packet from a source with no controller means a peer started a handshake.
acceptor_loop(Kernel) ->
    receive
        {zigbee_packet, Src, Packet} ->
            io:format("zigbee_dist: accept: ~p bytes from ~p~n", [byte_size(Packet), Src]),
            {ok, Ctrl} = zigbee_dist_controller:start(Src, Packet),
            'Elixir.Zigbeam.ZigbeeLink':route(Src, Ctrl),
            Kernel ! {accept, self(), Ctrl, zigbee, zigbee},
            receive
                {Kernel, controller, SupervisorPid} ->
                    io:format("zigbee_dist: accept: kernel assigned ~p~n", [SupervisorPid]),
                    true = zigbee_dist_controller:supervisor(Ctrl, SupervisorPid);
                {Kernel, unsupported_protocol} ->
                    exit(Ctrl, shutdown)
            end,
            acceptor_loop(Kernel);
        _Other ->
            acceptor_loop(Kernel)
    end.

accept_connection(AcceptPid, Ctrl, MyNode, Allowed, SetupTime) ->
    io:format("zigbee_dist: accept_connection ~p ~p~n", [AcceptPid, Ctrl]),
    case whereis(?ACCEPTOR) of
        AcceptPid ->
            Kernel = self(),
            spawn_opt(
                fun() ->
                    Timer = dist_util:start_timer(SetupTime),
                    HSData = hs_data(Kernel, MyNode, Ctrl, Allowed, undefined, undefined, undefined, Timer),
                    dist_util:handshake_other_started(HSData)
                end,
                dist_util:net_ticker_spawn_options()
            );
        _ ->
            serial_dist:accept_connection(AcceptPid, Ctrl, MyNode, Allowed, SetupTime)
    end.

setup(Node, Type, MyNode, LongOrShortNames, SetupTime) ->
    io:format("zigbee_dist: setup ~p~n", [Node]),
    case is_zigbee_node(Node) of
        true ->
            Kernel = self(),
            spawn_opt(
                fun() -> do_setup(Kernel, Node, Type, MyNode, SetupTime) end,
                dist_util:net_ticker_spawn_options()
            );
        false ->
            serial_dist:setup(Node, Type, MyNode, LongOrShortNames, SetupTime)
    end.

do_setup(Kernel, Node, Type, MyNode, SetupTime) ->
    Timer = dist_util:start_timer(SetupTime),
    case 'Elixir.Zigbeam.ZigbeeLink':lookup(Node) of
        nil ->
            ?shutdown2(Node, {unknown_zigbee_peer, Node});
        Src when is_integer(Src) ->
            {ok, Ctrl} = zigbee_dist_controller:start(Src),
            'Elixir.Zigbeam.ZigbeeLink':route(Src, Ctrl),
            true = zigbee_dist_controller:supervisor(Ctrl, self()),
            dist_util:reset_timer(Timer),
            HSData = hs_data(Kernel, MyNode, Ctrl, [], Node, 6, Type, Timer),
            io:format("zigbee_dist: setup: handshake_we_started via ~p to ~p~n", [Ctrl, Src]),
            dist_util:handshake_we_started(HSData)
    end.

hs_data(Kernel, MyNode, Ctrl, Allowed, OtherNode, OtherVersion, Type, Timer) ->
    #hs_data{
        kernel_pid = Kernel,
        this_node = MyNode,
        socket = Ctrl,
        timer = Timer,
        this_flags = 0,
        allowed = Allowed,
        other_node = OtherNode,
        other_version = OtherVersion,
        f_send = fun zigbee_dist_controller:send/2,
        f_recv = fun zigbee_dist_controller:recv/3,
        f_setopts_pre_nodeup = fun zigbee_dist_controller:setopts_pre_nodeup/1,
        f_setopts_post_nodeup = fun zigbee_dist_controller:setopts_post_nodeup/1,
        f_getll = fun zigbee_dist_controller:getll/1,
        f_address = fun zigbee_dist_controller:address/2,
        f_handshake_complete = fun zigbee_dist_controller:handshake_complete/3,
        mf_tick = fun zigbee_dist_controller:tick/1,
        mf_getstat = fun zigbee_dist_controller:getstat/1,
        request_type = Type
    }.

close({zigbee, none}) ->
    ok;
close({zigbee, Serial}) ->
    serial_dist:close(Serial);
close(_) ->
    ok.

select(_Node) ->
    true.

is_node_name(Node) when is_atom(Node) ->
    case string:split(atom_to_list(Node), "@") of
        [_, _] -> true;
        _ -> false
    end;
is_node_name(_) ->
    false.

is_zigbee_node(Node) when is_atom(Node) ->
    case string:split(atom_to_list(Node), "@") of
        [_, "zigbee.local"] -> true;
        _ -> false
    end;
is_zigbee_node(_) ->
    false.
