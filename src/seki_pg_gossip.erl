-module(seki_pg_gossip).

-moduledoc """
Gossip process for distributed rate limiting.

Joins a `pg` group and periodically broadcasts local ETS state to all peers.
Merges received state using algorithm-aware strategies (max counts for sliding
windows, lower tokens for token buckets, higher TAT for GCRA).

The scope of the group is started if it is not running, and the group is
joined again when the scope is restarted. A scope that was already running
belongs to whoever started it: when it stops, the process waits for it to be
started again and does not start it itself. Started with an `owner`, the process
stops when that process exits.

Used internally by `seki_backend_pg`.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/1,
    stop/1,
    merge_entries_for_test/2,
    merge_step/3
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-define(GOSSIP_VERSION, 2).
-define(REJOIN_PAUSE, 100).

-record(state, {
    scope :: atom(),
    group :: term(),
    tab :: ets:tid(),
    interval :: pos_integer(),
    algorithm :: seki:algorithm() | undefined,
    window :: pos_integer() | undefined,
    scope_monitor :: reference() | undefined,
    owner_monitor :: reference() | undefined,
    own_scope :: boolean()
}).

%%----------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------

start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

stop(Pid) ->
    gen_server:stop(Pid).

%%----------------------------------------------------------------------
%% gen_server callbacks
%%----------------------------------------------------------------------

%% Whose scope it is was settled when the limiter was made, and comes with
%% the arguments, so a gossip process that is started again while a scope of
%% the application is down does not start that scope: it waits for it.
init(#{scope := Scope, group := Group, tab := Tab, interval := Interval} = Opts) ->
    Own = maps:get(own_scope, Opts, true),
    State = #state{
        scope = Scope,
        group = Group,
        tab = Tab,
        interval = Interval,
        algorithm = maps:get(algorithm, Opts, undefined),
        window = maps:get(window, Opts, undefined),
        scope_monitor = undefined,
        owner_monitor = undefined,
        own_scope = Own
    },
    case join(Scope, Group, Own) of
        {ok, ScopeMonitor} ->
            ?LOG_INFO(
                #{
                    msg => gossip_joined,
                    scope => Scope,
                    group => seki_name:label(Group),
                    interval => Interval
                },
                #{domain => [seki]}
            ),
            schedule_gossip(Interval),
            {ok, State#state{
                scope_monitor = ScopeMonitor,
                owner_monitor = owner_monitor(Opts),
                own_scope = seki_scope_sup:own(Scope)
            }};
        no_scope when Own ->
            {stop, {no_scope, Scope}};
        no_scope ->
            ?LOG_WARNING(
                #{
                    msg => gossip_scope_down,
                    scope => Scope,
                    group => seki_name:label(Group),
                    restarted_by_seki => false,
                    reason => not_running
                },
                #{domain => [seki]}
            ),
            schedule_gossip(Interval),
            {ok, rejoined(State#state{owner_monitor = owner_monitor(Opts)})}
    end.

handle_call(Request, _From, State) ->
    ok = seki_unexpected:dropped(?MODULE, call, Request),
    {reply, {error, unknown}, State}.

handle_cast(
    {seki_gossip, ?GOSSIP_VERSION, Algorithm, Entries}, #state{algorithm = Algorithm} = State
) when
    is_list(Entries)
->
    ok = merge_gossip(Entries, erlang:monotonic_time(millisecond), State),
    {noreply, State};
handle_cast(Message, State) ->
    ok = seki_unexpected:dropped(?MODULE, cast, Message),
    {noreply, State}.

handle_info(gossip, #state{interval = Interval} = State) ->
    broadcast_state(State),
    schedule_gossip(Interval),
    {noreply, State};
handle_info({'DOWN', Monitor, process, _Scope, Reason}, #state{scope_monitor = Monitor} = State) ->
    ?LOG_WARNING(
        #{
            msg => gossip_scope_down,
            scope => State#state.scope,
            group => seki_name:label(State#state.group),
            restarted_by_seki => State#state.own_scope,
            reason => Reason
        },
        #{domain => [seki]}
    ),
    {noreply, rejoined(State)};
handle_info(rejoin, #state{scope_monitor = undefined} = State) ->
    {noreply, rejoined(State)};
handle_info({'DOWN', Monitor, process, _Owner, _Reason}, #state{owner_monitor = Monitor} = State) ->
    {stop, normal, State};
handle_info(Message, State) ->
    ok = seki_unexpected:dropped(?MODULE, info, Message),
    {noreply, State}.

terminate(Reason, #state{scope = Scope, group = Group}) ->
    ?LOG_INFO(
        #{msg => gossip_leaving, scope => Scope, group => seki_name:label(Group), reason => Reason},
        #{domain => [seki]}
    ),
    try
        pg:leave(Scope, Group, self())
    catch
        exit:_NoScope -> not_joined
    end.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

%% The scope is watched from before the group is joined, so a scope that goes
%% at any time after is noticed. A scope that is restarted has forgotten its
%% members, and the group is joined again.
%%
%% Only a scope seki holds is started here. A scope the application started
%% is restarted by its own supervisor: starting it here would take its name,
%% and the application's start of it would fail.
join(Scope, Group, Own) ->
    case scope(Scope, Own) of
        ok ->
            Monitor = monitor(process, Scope),
            try pg:join(Scope, Group, self()) of
                ok -> {ok, Monitor}
            catch
                exit:_NoScope ->
                    true = demonitor(Monitor, [flush]),
                    no_scope
            end;
        {error, not_a_scope} ->
            no_scope
    end.

scope(Scope, true) -> seki_scope_sup:ensure(Scope);
scope(Scope, false) -> seki_scope_sup:running(Scope).

rejoined(#state{scope = Scope, group = Group, own_scope = Own} = State) ->
    case join(Scope, Group, Own) of
        {ok, Monitor} ->
            State#state{scope_monitor = Monitor, own_scope = seki_scope_sup:own(Scope)};
        no_scope ->
            _ = erlang:send_after(?REJOIN_PAUSE, self(), rejoin),
            State#state{scope_monitor = undefined}
    end.

%% The table belongs to the process that started the backend. When that
%% process is gone the table is gone, and there is nothing left to gossip.
owner_monitor(#{owner := Owner}) when is_pid(Owner) -> monitor(process, Owner);
owner_monitor(#{}) -> undefined.

schedule_gossip(Interval) ->
    erlang:send_after(Interval, self(), gossip).

broadcast_state(#state{scope = Scope, group = Group, tab = Tab, algorithm = Algorithm}) ->
    Now = erlang:monotonic_time(millisecond),
    Entries = [
        {Key, Encoded}
     || {Key, Value} <- ets:tab2list(Tab), {ok, Encoded} <- [encode(Algorithm, Value, Now)]
    ],
    case Entries of
        [] ->
            ok;
        _ ->
            Self = self(),
            _ = [
                gen_server:cast(Peer, {seki_gossip, ?GOSSIP_VERSION, Algorithm, Entries})
             || Peer <- pg:get_members(Scope, Group), Peer =/= Self
            ],
            ok
    end.

%% Monotonic time differs between nodes by the gap in VM uptime, so the
%% timestamps in a limiter's state travel as offsets from the sender's now and
%% are rebased on the receiver's. Values in a table that no limiter owns are
%% not known to hold timestamps and travel as they are.
encode(undefined, Value, _Now) ->
    {ok, Value};
encode(Algorithm, Value, Now) ->
    shift(Algorithm, Value, -Now).

decode(undefined, Value, _Now) ->
    {ok, Value};
decode(Algorithm, Encoded, Now) ->
    shift(Algorithm, Encoded, Now).

shift(sliding_window, {Prev, Curr, WinStart}, By) when
    is_number(Prev), is_number(Curr), is_number(WinStart)
->
    {ok, {Prev, Curr, WinStart + By}};
shift(token_bucket, Bucket, By) ->
    shift_bucket(Bucket, By);
shift(leaky_bucket, Bucket, By) ->
    shift_bucket(Bucket, By);
shift(gcra, TAT, By) when is_number(TAT) ->
    {ok, TAT + By};
shift(_Algorithm, _Value, _By) ->
    skip.

shift_bucket({Amount, Timestamp}, By) when is_number(Amount), is_number(Timestamp) ->
    {ok, {Amount, Timestamp + By}};
shift_bucket(_Value, _By) ->
    skip.

merge_entries_for_test(Tab, Entries) ->
    merge_entries(Tab, Entries, undefined).

merge_entries(Tab, Entries, Window) ->
    lists:foreach(
        fun({Key, RemoteValue}) -> merge_stored(Tab, Key, RemoteValue, Window) end,
        Entries
    ).

%% Gossip is whatever another node sent. An entry that is not a key seki could
%% have stored, with a value in the limiter's shape, is passed over, and a
%% tail that is not a list ends the entries.
merge_gossip([Entry | Entries], Now, State) ->
    ok = merge_entry(Entry, Now, State),
    merge_gossip(Entries, Now, State);
merge_gossip(_End, _Now, _State) ->
    ok.

merge_entry({Key, Encoded}, Now, #state{tab = Tab, algorithm = Algorithm, window = Window}) ->
    case {seki_ets:is_literal(Key), decode(Algorithm, Encoded, Now)} of
        {true, {ok, Value}} -> merge_stored(Tab, Key, Value, Window);
        {_Literal, _Decoded} -> ok
    end;
merge_entry(_Entry, _Now, _State) ->
    ok.

merge_stored(Tab, Key, RemoteValue, Window) ->
    _ = seki_ets:atomic_update_stored(Tab, Key, {?MODULE, merge_step, [RemoteValue, Window]}),
    ok.

-doc false.
merge_step(not_found, RemoteValue, _Window) ->
    {ok, {write, RemoteValue}};
merge_step({ok, LocalValue}, RemoteValue, Window) ->
    case merge_value(LocalValue, RemoteValue, Window) of
        LocalValue -> {ok, keep};
        Merged -> {ok, {write, Merged}}
    end.

%% Merge strategies based on value shape.
%%
%% Sliding window: {PrevCount, CurrCount, WindowStart}
%% Each node aligns windows to its own clock, so window starts less than one
%% window apart are the same window: take the higher counts on the local start.
%% Otherwise take the entry with the most recent window.
merge_value({LP, LC, LW}, {RP, RC, RW}, Window) when
    is_integer(Window), abs(LW - RW) < Window
->
    {max(LP, RP), max(LC, RC), LW};
merge_value(Local, Remote, _Window) ->
    merge_value(Local, Remote).

merge_value({LP, LC, LW}, {_RP, _RC, RW}) when LW > RW ->
    {LP, LC, LW};
merge_value({_LP, _LC, _LW}, {RP, RC, RW}) when _LW < RW ->
    %% Remote has a newer window
    {RP, RC, RW};
merge_value({LP, LC, LW}, {RP, RC, _RW}) ->
    %% Same window: take max counts
    {max(LP, RP), max(LC, RC), LW};
%% Token bucket / Leaky bucket: {Tokens/Level, Timestamp}
%% Take the entry with the more recent timestamp.
%% For the same timestamp, take the lower token count (more consumed).
merge_value({LT, LTs}, {_RT, RTs}) when LTs > RTs ->
    {LT, LTs};
merge_value({_LT, LTs}, {RT, RTs}) when RTs > LTs ->
    {RT, RTs};
merge_value({LT, LTs}, {RT, _RTs}) ->
    {min(LT, RT), LTs};
%% GCRA: single timestamp (TAT)
%% Take the higher TAT (more rate-limited state wins).
merge_value(LTAT, RTAT) when is_number(LTAT), is_number(RTAT) ->
    max(LTAT, RTAT);
%% Unknown shape: prefer local
merge_value(Local, _Remote) ->
    Local.
