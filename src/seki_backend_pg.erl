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

- `scope`: pg scope atom (default: `seki_pg`). A scope that is not running is
  started under seki's supervisor; one that is running, such as a scope your
  application started, is used as it is.
- `group`: pg group. A limiter created with `seki:new_limiter/2` defaults to
  `{seki_limiter, Name}`, its own group; a backend started on its own defaults
  to `{seki_limiters, TableName}`. Limiters that share a group merge each
  other's keys, so give each limiter its own group.
- `gossip_interval`: broadcast interval in ms (default: 1000)

`init/1` returns `{error, {invalid_option, Key}}` when `scope` or
`table_name` is not an atom, when `scope` is the registered name of something
that is not a `pg` scope, or when `gossip_interval` is not a whole number of
milliseconds from 1 to 4294967295.

## The gossip process

The gossip process is supervised by seki and is not linked to the process
that called `init/1`, which owns the table. A gossip process that dies is
restarted on the same table: the counters are kept and no limiter is lost. It
joins its group again when its scope is restarted. It stops when
`terminate/1` is called or when the owner of the table exits.

A gossip process that dies more than 3 times in 10 seconds is not restarted
again. Its limiter keeps counting on this node and no longer shares its state
with the other nodes until it is deleted and created again.

Without the seki application running, the scope is started unsupervised and
the gossip process is linked to the caller of `init/1`.
""".

-behaviour(seki_backend).

-include_lib("kernel/include/logger.hrl").

-export([
    init/1,
    get/2,
    put/3,
    update/4,
    atomic_update/3,
    delete/2,
    cleanup/2,
    cleanup_arrivals/1,
    terminate/1
]).

-record(state, {
    local_tab :: ets:table(),
    gossip_pid :: pid(),
    scope :: atom()
}).

%%----------------------------------------------------------------------
%% Backend callbacks
%%----------------------------------------------------------------------

init(Opts) ->
    Kinds = [{scope, atom}, {table_name, atom}, {gossip_interval, interval}],
    case seki_options:check(Opts, Kinds) of
        ok -> start(Opts);
        {error, Reason} -> {error, Reason}
    end.

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

cleanup_arrivals(#state{local_tab = Tab}) ->
    seki_ets:cleanup_arrivals(Tab).

terminate(#state{local_tab = Tab, gossip_pid = GossipPid}) ->
    ?LOG_INFO(#{msg => distributed_backend_stopping}, #{domain => [seki]}),
    ok = seki_gossip_sup:stop_gossip(Tab, GossipPid),
    ets:delete(Tab),
    ok.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

start(Opts) ->
    Scope = maps:get(scope, Opts, seki_pg),
    case seki_scope_sup:ensure(Scope) of
        ok -> start(Scope, Opts);
        {error, not_a_scope} -> {error, {invalid_option, scope}}
    end.

start(Scope, Opts) ->
    TableName = maps:get(table_name, Opts, seki_pg_data),
    Group = maps:get(group, Opts, {seki_limiters, TableName}),
    Tab = ets:new(TableName, [
        set,
        public,
        {write_concurrency, auto}
    ]),
    GossipInterval = maps:get(gossip_interval, Opts, 1000),
    Limiter = maps:get(seki_limiter, Opts, #{}),
    Gossip = #{
        scope => Scope,
        group => Group,
        tab => Tab,
        owner => self(),
        interval => GossipInterval,
        algorithm => maps:get(algorithm, Limiter, undefined),
        window => maps:get(window, Limiter, undefined)
    },
    case seki_gossip_sup:start_gossip(Tab, Gossip) of
        {ok, GossipPid} ->
            ?LOG_INFO(
                #{
                    msg => distributed_backend_started,
                    scope => Scope,
                    group => seki_name:label(Group),
                    gossip_interval => GossipInterval
                },
                #{domain => [seki]}
            ),
            {ok, #state{
                local_tab = Tab,
                gossip_pid = GossipPid,
                scope = Scope
            }};
        {error, Reason} ->
            true = ets:delete(Tab),
            {error, Reason}
    end.
