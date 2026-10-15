%% Distribution controller for one Zigbee peer (see zigbee_dist).
%%
%% Handshake phase: dist_util calls send/2 and recv/3 synchronously; each
%% handshake message is one packet. Data phase (after handshake_complete/3):
%% packets from the VM (erlang:dist_ctrl_get_data) go out as they come,
%% incoming packets go to erlang:dist_ctrl_put_data. An empty packet is a tick.
-module(zigbee_dist_controller).

-include_lib("kernel/include/net_address.hrl").

-behaviour(gen_server).

-export([
    start/1, start/2,
    supervisor/2,
    recv/3,
    send/2,
    setopts_pre_nodeup/1,
    setopts_post_nodeup/1,
    getll/1,
    address/2,
    tick/1,
    getstat/1,
    handshake_complete/3
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(LINK, 'Elixir.Zigbeam.ZigbeeLink').

-record(state, {
    src :: non_neg_integer(),
    dhandle :: reference() | undefined,
    queue :: [binary()],
    waiting :: {gen_server:from(), reference()} | undefined,
    received :: non_neg_integer(),
    sent :: non_neg_integer()
}).

%% Outgoing connection: no data yet.
start(Src) ->
    gen_server:start(?MODULE, {Src, []}, []).

%% Incoming connection: the first handshake packet already arrived.
start(Src, FirstPacket) ->
    gen_server:start(?MODULE, {Src, [FirstPacket]}, []).

supervisor(Ctrl, Pid) ->
    gen_server:call(Ctrl, {supervisor, Pid}).

recv(Ctrl, Length, Timeout) ->
    gen_server:call(Ctrl, {recv, Length, Timeout}, infinity).

send(Ctrl, Data) ->
    gen_server:call(Ctrl, {send, Data}, infinity).

setopts_pre_nodeup(_Ctrl) -> ok.
setopts_post_nodeup(_Ctrl) -> ok.

getll(Ctrl) -> {ok, Ctrl}.

address(_Ctrl, Node) ->
    case string:split(atom_to_list(Node), "@") of
        [_Name, Host] ->
            #net_address{address = zigbee, host = Host, protocol = zigbee, family = zigbee};
        _ ->
            {error, no_node}
    end.

tick(Ctrl) ->
    gen_server:cast(Ctrl, tick).

getstat(Ctrl) ->
    gen_server:call(Ctrl, getstat).

handshake_complete(Ctrl, _Node, DHandle) ->
    gen_server:cast(Ctrl, {handshake_complete, DHandle}),
    ok.

%% gen_server

init({Src, Initial}) ->
    {ok, #state{src = Src, queue = Initial, received = length(Initial), sent = 0}}.

handle_call({supervisor, Pid}, _From, State) ->
    {reply, link(Pid), State};
handle_call({recv, _Length, _Timeout}, _From, #state{queue = [P | Rest]} = State) ->
    {reply, {ok, P}, State#state{queue = Rest}};
handle_call({recv, _Length, Timeout}, From, #state{queue = []} = State) ->
    Ref = make_ref(),
    case Timeout of
        infinity -> ok;
        _ -> erlang:send_after(Timeout, self(), {recv_timeout, Ref})
    end,
    {noreply, State#state{waiting = {From, Ref}}};
handle_call({send, Data}, _From, #state{src = Src, sent = Sent} = State) ->
    Reply = ?LINK:send_packet(Src, iolist_to_binary(Data)),
    {reply, Reply, State#state{sent = Sent + 1}};
handle_call(getstat, _From, #state{received = R, sent = S} = State) ->
    {reply, {ok, R, S, 0}, State}.

handle_cast(tick, #state{src = Src, sent = Sent} = State) ->
    case ?LINK:send_packet(Src, <<>>) of
        ok ->
            {noreply, State#state{sent = Sent + 1}};
        {error, Reason} ->
            io:format("zigbee_ctrl: tick failed: ~p~n", [Reason]),
            {stop, normal, State}
    end;
handle_cast({handshake_complete, DHandle}, #state{queue = Queue} = State) ->
    io:format("zigbee_ctrl: handshake complete~n"),
    ok = erlang:dist_ctrl_get_data_notification(DHandle),
    lists:foreach(fun(P) -> put_data(DHandle, P) end, Queue),
    {noreply, State#state{dhandle = DHandle, queue = []}}.

handle_info(dist_data, State) ->
    {noreply, send_data_loop(State)};
handle_info({zigbee_packet, Src, Packet}, #state{src = Src, received = R} = State0) ->
    State = State0#state{received = R + 1},
    case State of
        #state{dhandle = undefined, waiting = {From, _Ref}} ->
            gen_server:reply(From, {ok, Packet}),
            {noreply, State#state{waiting = undefined}};
        #state{dhandle = undefined, queue = Q} ->
            {noreply, State#state{queue = Q ++ [Packet]}};
        #state{dhandle = DHandle} ->
            put_data(DHandle, Packet),
            {noreply, State}
    end;
handle_info({recv_timeout, Ref}, #state{waiting = {From, Ref}} = State) ->
    gen_server:reply(From, {error, timeout}),
    {noreply, State#state{waiting = undefined}};
handle_info({zigbee_link_down, Reason}, State) ->
    %% Expected end of a connection (peer rebooted); stop quietly rather
    %% than with a crash report. The linked supervisor still goes down.
    io:format("zigbee_ctrl: link down: ~p~n", [Reason]),
    {stop, normal, State};
handle_info(_Other, State) ->
    {noreply, State}.

terminate(Reason, _State) ->
    io:format("zigbee_ctrl: terminate ~p~n", [Reason]),
    ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

put_data(_DHandle, <<>>) -> ok;
put_data(DHandle, Packet) -> ok = erlang:dist_ctrl_put_data(DHandle, Packet).

send_data_loop(#state{dhandle = DHandle, src = Src, sent = Sent} = State) ->
    case erlang:dist_ctrl_get_data(DHandle) of
        none ->
            ok = erlang:dist_ctrl_get_data_notification(DHandle),
            State;
        Data ->
            case ?LINK:send_packet(Src, iolist_to_binary(Data)) of
                ok ->
                    send_data_loop(State#state{sent = Sent + 1});
                {error, Reason} ->
                    io:format("zigbee_ctrl: send failed: ~p~n", [Reason]),
                    exit(normal)
            end
    end.
