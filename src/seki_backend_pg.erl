-module(seki_backend_pg).

-moduledoc """
Distributed rate limiter backend using Erlang's `pg` module.

Each node maintains local ETS counters. A gossip process (`seki_pg_gossip`)
periodically broadcasts state to peers, which merge using last-writer-wins.
Local updates are atomic per key, like `seki_backend_ets`; gossip merges use
the same compare-and-swap so they never overwrite a concurrent local check.
Across nodes the state is eventually consistent — suitable for most rate limiting use cases.

## Options

- `scope` — pg scope atom (default: `seki_pg`)
- `group` — pg group atom (default: `seki_limiters`)
- `gossip_interval` — broadcast interval in ms (default: 1000)
""".

-behaviour(seki_backend).

-export([
    init/1,
    get/2,
    put/3,
    update/4,
    atomic_update/3,
    delete/2,
    cleanup/2,
    terminate/1
]).

-record(state, {
    local_tab :: ets:tid(),
    gossip_pid :: pid(),
    scope :: atom()
}).

%%----------------------------------------------------------------------
%% Backend callbacks
%%----------------------------------------------------------------------

init(Opts) ->
    Scope = maps:get(scope, Opts, seki_pg),
    Group = maps:get(group, Opts, seki_limiters),
    TableName = maps:get(table_name, Opts, seki_pg_data),
    %% Ensure pg scope exists
    ok = ensure_pg_scope(Scope),
    %% Local ETS for fast reads/writes
    Tab = ets:new(TableName, [
        set,
        public,
        {write_concurrency, auto}
    ]),
    %% Start gossip process
    GossipInterval = maps:get(gossip_interval, Opts, 1000),
    {ok, GossipPid} = seki_pg_gossip:start_link(#{
        scope => Scope,
        group => Group,
        tab => Tab,
        interval => GossipInterval
    }),
    logger:info(
        "Distributed backend started (scope=~p, group=~p, gossip_interval=~pms)",
        [Scope, Group, GossipInterval],
        #{domain => [seki]}
    ),
    {ok, #state{
        local_tab = Tab,
        gossip_pid = GossipPid,
        scope = Scope
    }}.

get(#state{local_tab = Tab}, Key) ->
    case ets:lookup(Tab, Key) of
        [{Key, Value}] -> {ok, Value};
        [] -> not_found
    end.

put(#state{local_tab = Tab}, Key, Value) ->
    true = ets:insert(Tab, {Key, Value}),
    ok.

update(#state{local_tab = Tab}, Key, Fun, Default) ->
    seki_ets:update(Tab, Key, Fun, Default).

atomic_update(#state{local_tab = Tab}, Key, Step) ->
    seki_ets:atomic_update(Tab, Key, Step).

delete(#state{local_tab = Tab}, Key) ->
    true = ets:delete(Tab, Key),
    ok.

cleanup(#state{local_tab = Tab}, OlderThan) ->
    seki_ets:cleanup(Tab, OlderThan).

terminate(#state{local_tab = Tab, gossip_pid = GossipPid}) ->
    logger:info(
        "Distributed backend shutting down, stopping gossip",
        #{domain => [seki]}
    ),
    seki_pg_gossip:stop(GossipPid),
    ets:delete(Tab),
    ok.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

ensure_pg_scope(Scope) ->
    case pg:start(Scope) of
        {ok, _Pid} -> ok;
        {error, {already_started, _Pid}} -> ok
    end.
