# Getting Started

Seki provides resilience primitives for BEAM applications — rate limiting, circuit breaking,
bulkheads, retry, and more. It works natively from Erlang, Elixir, Gleam, and LFE.

## Installation

### Erlang (rebar3)

```erlang
%% rebar.config
{deps, [
    {seki, "~> 0.1"}
]}.
```

### Elixir (Mix)

```elixir
# mix.exs
defp deps do
  [
    {:seki, "~> 0.1"}
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

Every name is a process, and seki does not limit how many there are. A name
made from a value a client chooses (a tenant id read from a request, an IP
address, a header) lets that client start one process per value it sends. Make
such a name only from a value that has been checked against what you know
(the tenants that exist), or delete what is no longer used
(`seki:delete_breaker/1`, `seki:delete_limiter/1`). A limiter needs no name
per client: one limiter counts per key (`seki:check/2`).

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
    Logger.warning("Circuit breaker #{name}: #{from} -> #{to}")
end, %{})
```

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

## Next Steps

- [Rate Limiting Guide](rate-limiting.md) — choosing algorithms, distributed rate limiting
- [Circuit Breaker Guide](circuit-breaker.md) — thresholds, error classifiers, window types
- [Nova Integration](nova-integration.md) — plugins, controllers, application setup
- [Phoenix Integration](phoenix-integration.md) — plugs, contexts, application setup
- [Advanced Patterns](advanced-patterns.md) — adaptive concurrency, load shedding, hedging, health checks
