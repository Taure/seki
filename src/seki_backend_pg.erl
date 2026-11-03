-module(seki_backend_pg).

-moduledoc """
Distributed rate limiter backend using Erlang's `pg` module.

Each node maintains local ETS counters. A gossip process (`seki_pg_gossip`)
periodically broadcasts state to peers, which merge using last-writer-wins.
Local updates are atomic per key, like `seki_backend_ets`; gossip merges use
the same compare-and-swap so they never overwrite a concurrent local check.

For a limiter created with `seki:new_limiter/2`, gossip sends the timestamps
in its state relative to the sender's clock and rebases them on the receiver,
because monotonic time differs between nodes. Sliding windows that start less
than one window apart are merged as the same window. Gossip is tagged with the
limiter's algorithm and a format version; gossip for another algorithm, or
from 0.4.x nodes, is ignored. Values in a table that no limiter owns, such as
one written through `update/4` on a standalone backend, are gossiped as they
are and never rebased. Across nodes the state is eventually consistent, which
suits most rate limiting use cases.

## Options

- `scope`: pg scope atom (default: `seki_pg`)
- `group`: pg group (default: `{seki_limiters, TableName}`, one group per
  limiter). Limiters that share a group merge each other's keys, so give each
  limiter its own group.
- `gossip_interval`: broadcast interval in ms (default: 1000)
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
    TableName = maps:get(table_name, Opts, seki_pg_data),
    Group = maps:get(group, Opts, {seki_limiters, TableName}),
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
    Limiter = maps:get(seki_limiter, Opts, #{}),
    {ok, GossipPid} = seki_pg_gossip:start_link(#{
        scope => Scope,
        group => Group,
        tab => Tab,
        interval => GossipInterval,
        algorithm => maps:get(algorithm, Limiter, undefined),
        window => maps:get(window, Limiter, undefined)
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
    seki_ets:lookup(Tab, Key).

put(#state{local_tab = Tab}, Key, Value) ->
    seki_ets:insert(Tab, Key, Value).

update(#state{local_tab = Tab}, Key, Fun, Default) ->
    seki_ets:update(Tab, Key, Fun, Default).

atomic_update(#state{local_tab = Tab}, Key, Step) ->
    seki_ets:atomic_update(Tab, Key, Step).

delete(#state{local_tab = Tab}, Key) ->
    seki_ets:delete(Tab, Key).

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
