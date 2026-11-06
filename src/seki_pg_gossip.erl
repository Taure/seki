-module(seki_pg_gossip).

-moduledoc """
Gossip process for distributed rate limiting.

Joins a `pg` group and periodically broadcasts local ETS state to all peers.
Merges received state using algorithm-aware strategies (max counts for sliding
windows, lower tokens for token buckets, higher TAT for GCRA).

Used internally by `seki_backend_pg`.
""".

-behaviour(gen_server).

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

-record(state, {
    scope :: atom(),
    group :: term(),
    tab :: ets:tid(),
    interval :: pos_integer(),
    algorithm :: seki:algorithm() | undefined,
    window :: pos_integer() | undefined
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

init(#{scope := Scope, group := Group, tab := Tab, interval := Interval} = Opts) ->
    ok = pg:join(Scope, Group, self()),
    logger:info(
        "Gossip joined pg group ~p:~p (interval=~pms)",
        [Scope, Group, Interval],
        #{domain => [seki]}
    ),
    schedule_gossip(Interval),
    {ok, #state{
        scope = Scope,
        group = Group,
        tab = Tab,
        interval = Interval,
        algorithm = maps:get(algorithm, Opts, undefined),
        window = maps:get(window, Opts, undefined)
    }}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(
    {seki_gossip, ?GOSSIP_VERSION, Algorithm, Entries},
    #state{tab = Tab, algorithm = Algorithm, window = Window} = State
) when is_list(Entries) ->
    Now = erlang:monotonic_time(millisecond),
    merge_entries(
        Tab,
        [
            {Key, Value}
         || {Key, Encoded} <- Entries, {ok, Value} <- [decode(Algorithm, Encoded, Now)]
        ],
        Window
    ),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(gossip, #state{interval = Interval} = State) ->
    broadcast_state(State),
    schedule_gossip(Interval),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(Reason, #state{scope = Scope, group = Group}) ->
    logger:info(
        "Gossip leaving pg group ~p:~p (reason=~p)",
        [Scope, Group, Reason],
        #{domain => [seki]}
    ),
    pg:leave(Scope, Group, self()),
    ok.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

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
            Members = pg:get_members(Scope, Group),
            Self = self(),
            Peers = [P || P <- Members, P =/= Self],
            lists:foreach(
                fun(Peer) ->
                    gen_server:cast(Peer, {seki_gossip, ?GOSSIP_VERSION, Algorithm, Entries})
                end,
                Peers
            )
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
        fun({Key, RemoteValue}) ->
            _ = seki_ets:atomic_update_stored(
                Tab, Key, {?MODULE, merge_step, [RemoteValue, Window]}
            )
        end,
        Entries
    ).

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
