-module(seki_backend_ets).

-moduledoc """
ETS-based storage backend for rate limiting. Default backend.

Uses a public ETS table tuned for concurrent writes. Updates are atomic per
key: a compare-and-swap on the stored value. When another process changed the
value in between, the update moves to a worker process that owns the key and
retries there, so contending checks queue instead of spinning. Concurrent
checks of one key never lose a write. Suitable for single-node deployments.
For distributed rate limiting, see `seki_backend_pg`.
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

init(Opts) ->
    TableName = maps:get(table_name, Opts, seki_limiter_data),
    Tab = ets:new(TableName, [
        set,
        public,
        {write_concurrency, auto}
    ]),
    {ok, Tab}.

get(Tab, Key) ->
    seki_ets:lookup(Tab, Key).

put(Tab, Key, Value) ->
    seki_ets:insert(Tab, Key, Value).

update(Tab, Key, Fun, Default) ->
    seki_ets:update(Tab, Key, Fun, Default).

atomic_update(Tab, Key, Step) ->
    seki_ets:atomic_update(Tab, Key, Step).

delete(Tab, Key) ->
    seki_ets:delete(Tab, Key).

cleanup(Tab, OlderThan) ->
    seki_ets:cleanup(Tab, OlderThan).

terminate(Tab) ->
    ets:delete(Tab),
    ok.
