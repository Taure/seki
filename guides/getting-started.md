# Getting Started

Seki provides resilience primitives for BEAM applications — rate limiting, circuit breaking,
bulkheads, retry, and more. It works natively from Erlang, Elixir, Gleam, and LFE.

## Installation

### Erlang (rebar3)

```erlang
%% rebar.config
{deps, [
    {seki, "~> 0.6"}
]}.
```

### Elixir (Mix)

```elixir
# mix.exs
defp deps do
  [
    {:seki, "~> 0.6"}
  ]
end
```

Seki starts automatically as an OTP application. No additional configuration is required.

## Your First Rate Limiter

Rate limiters protect resources from being overwhelmed. Create one in your application
startup and check it before processing requests.

### Erlang

```erlang
%% In your application:start/2
ok = seki:new_limiter(api_limit, #{
    algorithm => sliding_window,
    limit => 100,
    window => timer:minutes(1)
}).

%% Later, in request handling
case seki:check(api_limit, UserId) of
    {allow, #{remaining := Remaining}} ->
        handle_request(Req);
    {deny, #{retry_after := Ms}} ->
        {429, <<"Rate limited">>}
end.
```

### Elixir

```elixir
# In your Application.start/2
:ok = :seki.new_limiter(:api_limit, %{
  algorithm: :sliding_window,
  limit: 100,
  window: :timer.minutes(1)
})

# Later, in request handling
case :seki.check(:api_limit, user_id) do
  {:allow, %{remaining: remaining}} ->
    handle_request(conn)
  {:deny, %{retry_after: ms}} ->
    send_resp(conn, 429, "Rate limited")
end
```

## Your First Circuit Breaker

Circuit breakers prevent cascading failures when a dependency is down. They track
failure rates and stop sending requests when failures exceed a threshold.

### Erlang

```erlang
%% In your application:start/2
{ok, _} = seki:new_breaker(db_pool, #{
    failure_threshold => 50,
    wait_duration => 30000,
    half_open_requests => 5
}).

%% In your business logic
case seki:call(db_pool, fun() -> db:query(SQL) end) of
    {ok, Result} -> Result;
    {error, circuit_open} -> cached_result();
    {error, Reason} -> handle_error(Reason)
end.
```

### Elixir

```elixir
# In your Application.start/2
{:ok, _} = :seki.new_breaker(:db_pool, %{
  failure_threshold: 50,
  wait_duration: 30_000,
  half_open_requests: 5
})

# In your business logic
case :seki.call(:db_pool, fn -> Repo.all(User) end) do
  {:ok, users} -> users
  {:error, :circuit_open} -> cached_users()
  {:error, reason} -> handle_error(reason)
end
```

## Combining Primitives

Seki primitives compose naturally. The `execute/3` function chains rate limiting
and circuit breaking in a single call:

```erlang
case seki:execute(db_breaker, api_limiter, fun() -> db:query(SQL) end) of
    {ok, Result} -> Result;
    {error, circuit_open} -> fallback();
    {error, {rate_limited, #{retry_after := Ms}}} -> rate_limited(Ms)
end.
```

For more complex pipelines, compose them yourself:

```erlang
handle_request(UserId, Fun) ->
    case seki:check(api_limit, UserId) of
        {deny, Info} ->
            {error, {rate_limited, Info}};
        {allow, _} ->
            case seki_bulkhead:call(external_api, fun() ->
                seki_retry:run(fun() ->
                    seki:call(db_breaker, Fun)
                end, #{max_attempts => 3, backoff => exponential})
            end) of
                {ok, {ok, Result}} -> {ok, Result};
                {ok, {error, Reason}} -> {error, Reason};
                {error, bulkhead_full} -> {error, overloaded}
            end
    end.
```

## Names

Everything seki starts is named by the term you give it. An atom is the usual
name; any other term works the same and creates no atom, which matters when
there is a breaker or a limiter per tenant, worker or host:

```erlang
{ok, _} = seki:new_breaker({payments, TenantId}, #{failure_threshold => 50}),
seki:call({payments, TenantId}, fun() -> charge(TenantId) end).
```

A process named by an atom is registered under that atom. One named by another
term is reached through seki's functions only.

A tuple is always a name on this node: `{Name, Node}` does not reach the
process `Name` on `Node`. A pid is not a name, and `seki:new_breaker/2` and the
other `new_*` functions return `{error, {invalid_name, Pid}}` for one. The pid
they return can be passed in place of the name to any function that calls the
process.

Every name is a process that lives until you delete it. A limiter is an ETS
table instead, plus a process and a `pg` group with the `seki_backend_pg`
backend. Nothing expires a name, and seki does not limit how many there are.
A name made from a value a client chooses (a tenant id read from a request, an
IP address, a header) lets that client start one per value it sends. Make such
a name only from a value that has been checked against what you know (the
tenants that exist), or delete what is no longer used
(`seki:delete_breaker/1`, `seki:delete_limiter/1`). A limiter needs no name
per client: one limiter counts per key (`seki:check/2`).

Each of these processes has a supervisor of its own, which restarts it when it
crashes: up to 3 times in 10 seconds. On the fourth crash in 10 seconds the
supervisor gives up and the name is gone, as if it had never been created,
until you create it again. No other name is affected. See
[Architecture](architecture.md) for the supervision tree and for what each
kind of process keeps across a restart.

Starting and deleting go through two shared supervisors, one for breakers and
one for the rest, one name at a time.

A name is written to seki's log lines and telemetry events. Do not put a
secret, such as an API key, in one.

## Unknown Names and a Stopped Application

seki never lets a request through because a name could not be found. A call
with a name that was never created, or made while the seki application is
stopped, raises, and the function you passed is not run:

| Call | Unknown name | seki stopped |
|------|--------------|--------------|
| `seki:call/2,3`, `seki:state/1` | exits `{noproc, _}` | exits `{noproc, _}` |
| `seki_bulkhead:call/2,3`, `acquire/1,2`, `status/1` | exits `{noproc, _}` | exits `{noproc, _}` |
| `seki_shed:admit/1,2`, `status/1` | exits `{noproc, _}` | exits `{noproc, _}` |
| `seki_adaptive:call/2,3`, `acquire/1`, `status/1` | exits `{noproc, _}` | exits `{noproc, _}` |
| `seki_health:check/1`, `readiness/1` | exits `{noproc, _}` | exits `{noproc, _}` |
| `seki_health:liveness/1` | returns `{error, unhealthy}` | returns `{error, unhealthy}` |
| `seki:check/2,3`, `inspect/2,3`, `reset/2`, `execute/3` | raises `error:{limiter_not_found, Name}` | raises `error:badarg` |
| `seki:reset_breaker/1`, `seki_bulkhead:release/1`, `seki_shed:complete/2`, `seki_adaptive:release/2` | returns `ok`, does nothing | returns `ok`, does nothing |

A name whose process crashed more than 3 times in 10 seconds is an unknown
name from then on, and every row above holds for it. A process that stopped
without crashing, for example one stopped with `gen_statem:stop/1`, is not
started again but keeps its name: calls exit with `{noproc, _}` and
`seki:new_breaker/2` or the other `new_*` function returns
`{error, already_present}`, until the name is deleted with
`seki:delete_breaker/1` or the other `delete_*` function. A breaker that was open
when that happened is open when it is created again
(see [When a Name Gives Up](architecture.md#when-a-name-gives-up)).

The names that are not atoms are kept in one table. If seki's registry and the
keeper of its table are both lost, the table is made again from the processes
that are still running, which takes well under a millisecond on an idle node.
In between, a call to a name that is not an atom exits with `{noproc, _}` and a
cast does nothing, as for an unknown name. The processes keep running, and
each is reached by its name again with the state it had: an open breaker is
still open. Names that are atoms are not affected. A process that is created
or restarted under such a name while the registry is restarting waits for it,
for 50 ms at most; after that `seki:new_breaker/2` and the other `new_*`
functions return `{error, {{noproc, _}, _}}`.

None of these is in the return types. A catch-all around such a call
(`catch _:_ -> allow`, or a bare `rescue` in Elixir) turns every one of them
into "allow". Catch them by name, and decide there whether the request goes
through.

## Telemetry

Every seki operation emits telemetry events under the `[seki, ...]` prefix.
Attach handlers in your application startup:

```erlang
telemetry:attach(<<"seki-logger">>, [seki, breaker, state_change], fun
    (_Event, _Measurements, #{name := Name, from := From, to := To}, _Config) ->
        logger:warning("Circuit breaker ~p: ~p -> ~p", [Name, From, To])
end, #{}).
```

```elixir
:telemetry.attach("seki-logger", [:seki, :breaker, :state_change], fn
  _event, _measurements, %{name: name, from: from, to: to}, _config ->
    Logger.warning("Circuit breaker #{inspect(name)}: #{from} -> #{to}")
end, %{})
```

`name` in the metadata is the term the breaker, limiter or other process was
named by, so it can be any term. Print it with `~p` or `inspect/1`. A handler
that raises is detached by `telemetry` and stays detached.

For OpenTelemetry integration, call `seki_otel:setup()` to automatically add span
events for all seki operations.

## Upgrading to 0.6

A tuple passed as a name is now a name on this node. Up to 0.5,
`seki:call({my_breaker, Node}, Fun)` reached the breaker `my_breaker` on
`Node`. From 0.6 it looks for a local breaker named `{my_breaker, Node}` and
exits with `noproc` when there is none. The same holds for bulkheads, load
shedders, adaptive limiters and health checkers, and their casts
(`seki:reset_breaker/1`, `seki_bulkhead:release/1`, `seki_shed:complete/2`,
`seki_adaptive:release/2`) return `ok` and do nothing. To use a process on
another node, call that node, for example with `erpc:call/4`.

`name` in telemetry metadata is whatever term the process or limiter was named
by, where it used to be an atom. A handler that assumes an atom
(`"#{metadata.name}"`, `atom_to_binary(Name)`) raises on the first event from a
term name, and `telemetry` then detaches it from every event it was attached
to. Print the name with `inspect/1` or `~p`.

A limiter on the `seki_backend_pg` backend gossips in the `pg` group
`{seki_limiter, Name}`. Up to 0.5 the group was `{seki_limiters, TableName}`,
with a table name made from the limiter's name. During a rolling upgrade the
nodes on 0.5 and the nodes on 0.6 are therefore in different groups: each side
counts on its own, and a client can be let through up to the limit on both,
until every node runs 0.6. A limiter given its own `group` in `backend_opts`
keeps that group and is not affected. If you cannot accept the looser limit
during the deploy, set `group` to the old value on the 0.6 nodes for one
release:

```erlang
backend_opts => #{group => {seki_limiters, seki_limiter_api_limit}}
```

The ETS table of a limiter named by an atom is no longer labelled
`seki_limiter_<name>`: every limiter's table is labelled `seki_limiter`. The
tables were never named tables, so only `ets:info(Tab, name)` and tools such
as Observer show the difference.

`seki:new_breaker/2`, `seki:new_bulkhead/2`, `seki:new_adaptive/2`,
`seki:new_shed/2` and `seki:new_health/2` check their options. An option of
the wrong kind, for example `max_concurrent => infinity` or
`failure_threshold => 150`, returns `{error, {invalid_option, Key}}` where it
used to start a process that died, or never tripped, when it was first used.

`seki:new_limiter/2` checks its options too, and no longer raises on a bad
one. `limit => 0`, an unknown `algorithm` or a missing `window` returns
`{error, {invalid_option, Key}}` or `{error, {missing_option, Key}}`, and a
backend that cannot start, for example `seki_backend_pg` with
`gossip_interval => 0`, returns `{error, {backend_failed, Reason}}`. Up to 0.5
each of these stopped the process that holds the limiters, and every limiter
on the node was lost with it.

A breaker that is restarted while open starts open, for what was left of
`wait_duration`, where it used to start closed. So does a breaker created
under a name that was open when its process was lost, unless
`seki:delete_breaker/1` was called for the name in between. A handler of
`[seki, breaker, state_change]` can therefore see `from => undefined` with
`to => open`.

The log lines that carry a name are now structured reports, for example
`#{msg => bulkhead_full, name => db_pool, max_concurrent => 25}`, where they
were formatted strings.

Every breaker, bulkhead, adaptive limiter, load shedder and health checker
now has a supervisor of its own, which tolerates 3 restarts in 10 seconds. Up
to 0.5 they shared two supervisors that tolerated 10 crashes in 60 seconds
between all their processes, and past that every breaker (or every other
process) on the node was lost. From 0.6 a process that crashes four times in
10 seconds is removed on its own: calls to its name exit with `{noproc, _}`,
as for a name that was never created, until it is created again, and nothing
else is touched. What you see from outside:

- `seki:new_breaker/2` and the other `new_*` functions still return the pid of
  the process itself, and the same errors as before.
- `supervisor:which_children(seki_breaker_sup)` and
  `supervisor:which_children(seki_process_sup)` list one
  `{Name, Pid, supervisor, [seki_name_sup]}` for each name, where they listed
  the process as a worker. Both supervisors are internal to seki.
- A crash loop is logged by the supervisor of the name
  (`{Pid, seki_name_sup}`), ending in one `reached_max_restart_intensity`
  report.
- While seki is stopped, `seki:new_breaker/2` and the other `new_*` functions
  exit with `{noproc, _}` as before; the call quoted in the exit reason is a
  different one.

The gossip process of a limiter on `seki_backend_pg` is no longer linked to
the process that holds the limiters. Up to 0.5 a gossip process that died took
every limiter on the node with it. From 0.6 it is restarted and no limiter is
lost. `seki_backend_pg` starts its `pg` scope under seki's supervisor, so the
scope stops when seki stops; a scope that is already running is used as it
is, and is left to whoever started it: when it stops, seki waits for it to be
started again and joins it then. A `scope` that is the registered name of
something else returns `{error, {backend_failed, {invalid_option, scope}}}`
from `seki:new_limiter/2`. See [Architecture](architecture.md) for the whole
tree.

A breaker with a count window (`window_type => count`, the default) and a
`window_size` below 5 now trips once its window is full and enough of the
calls in it failed. Up to
0.5 it never tripped, whatever failed, because it waited for five outcomes
and its window never held that many. Look at the breakers you create with a
small `window_size` before you upgrade: they can open for the first time.

Each name is now two processes, the process and its supervisor, and takes
about 7 KB where it took about 3 KB. Creating 100,000 names takes about two
seconds and stopping seki with them about one.

Limiter state is cleaned up differently:

- A `gcra` limiter forgets a key once the key is free again. Up to 0.5 it
  kept one value for every key it had ever seen.
- A limiter with a window longer than five minutes keeps a key for two
  windows after it was last seen. Up to 0.5 every key was forgotten ten
  minutes after it was last seen, which handed a client of such a limiter
  its whole limit again.
- A backend of your own is asked for the optional `cleanup_arrivals/1` to do
  the first of these (see `m:seki_backend`).

Also changed:

- seki needs OTP 28 or later.
- An `error_classifier` that raises, or returns something that is not a
  boolean, counts as an error and is logged. Up to 0.5 it crashed the breaker.
- A health checker with the default `vm_checks` reports `vm_memory` as
  healthy. Up to 0.5 that check always failed, so the checker was never better
  than `degraded`.
- A health check that returns something other than `{Health, Details}` is
  reported as `{unhealthy, #{error => {invalid_result, Returned}}}`. Up to 0.5
  it crashed the health checker.
- A seki process answers a call it does not know with
  `{error, unknown_request}` and drops a message it does not know, logging the
  first. Up to 0.5 it crashed.
- The processes `seki_registry`, `seki_registry_keeper`, `seki_registry_sup`,
  `seki_scope_sup` and `seki_gossip_sup` are registered, and the ETS tables
  `seki_registry` and `seki_breaker_trips` are named. The processes
  `seki_ets_worker_1` to `seki_ets_worker_N` are no longer registered.
- A span of `seki_otel` carries a name that is not an atom, a number or a
  short binary as printed text.

## Next Steps

- [Architecture](architecture.md): the supervision tree, and what is kept when a process is lost
- [Rate Limiting Guide](rate-limiting.md) — choosing algorithms, distributed rate limiting
- [Circuit Breaker Guide](circuit-breaker.md) — thresholds, error classifiers, window types
- [Nova Integration](nova-integration.md) — plugins, controllers, application setup
- [Phoenix Integration](phoenix-integration.md) — plugs, contexts, application setup
- [Advanced Patterns](advanced-patterns.md) — adaptive concurrency, load shedding, hedging, health checks
