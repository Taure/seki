# Advanced Patterns

Beyond the core primitives (rate limiting, circuit breaking, bulkhead, retry), seki
provides advanced resilience patterns for demanding production environments.

## Adaptive Concurrency

Static concurrency limits are guesswork. Adaptive concurrency automatically discovers
the right limit by observing latency. Inspired by Netflix's
[concurrency-limits](https://github.com/Netflix/concurrency-limits) library.

Two algorithms are available:

### AIMD (Additive Increase, Multiplicative Decrease)

Simple and stable. Increases the limit by a small amount on success, decreases it by
a ratio on failure. Good default for most services.

```erlang
{ok, _} = seki_adaptive:start_link(my_service, #{
    algorithm => aimd,
    initial_limit => 20,
    min_limit => 5,
    max_limit => 200,
    backoff_ratio => 0.9    %% reduce limit to 90% on failure
}).

case seki_adaptive:call(my_service, fun() -> do_work() end) of
    {ok, Result} -> Result;
    {error, limit_reached} -> {503, <<"Overloaded">>}
end.
```

```elixir
{:ok, _} = :seki_adaptive.start_link(:my_service, %{
  algorithm: :aimd,
  initial_limit: 20,
  min_limit: 5,
  max_limit: 200,
  backoff_ratio: 0.9
})

case :seki_adaptive.call(:my_service, fn -> do_work() end) do
  {:ok, result} -> result
  {:error, :limit_reached} -> {:error, :overloaded}
end
```

### Gradient

Tracks short-term and long-term latency via exponential moving averages. Increases
the limit when latency is stable, decreases when latency grows relative to the
baseline. Better for services where latency is the primary signal.

```erlang
{ok, _} = seki_adaptive:start_link(my_service, #{
    algorithm => gradient,
    initial_limit => 20,
    smoothing => 0.2,       %% EMA smoothing factor for short-term RTT
    tolerance => 1.5        %% latency must be 1.5x long-term to reduce
}).
```

### When to Use

Use adaptive concurrency instead of a static bulkhead when:

- You don't know the right concurrency limit ahead of time
- The downstream service's capacity varies (autoscaling, shared infrastructure)
- You want to maximize throughput without manual tuning

### Monitoring

```erlang
#{current_limit := Limit, in_flight := InFlight, available := Available}
    = seki_adaptive:status(my_service).
```

Telemetry events:

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[seki, adaptive, acquire]` | `in_flight`, `limit` | `name` |
| `[seki, adaptive, rejected]` | `limit` | `name` |
| `[seki, adaptive, limit_change]` | `old_limit`, `new_limit` | `name` |

## Load Shedding

When a service is overwhelmed, it's better to reject some requests quickly than to
let all requests degrade. Load shedding uses two mechanisms:

1. **Priority-based admission** — lower priority requests are shed first
2. **CoDel (Controlled Delay)** — tracks sojourn time and begins shedding when
   latency consistently exceeds a target

### Priority Levels

| Priority | Level | Default Threshold |
|----------|-------|-------------------|
| 0 | Critical | Never shed |
| 1 | Important | 90% capacity |
| 2 | Normal (default) | 80% capacity |
| 3 | Low | 70% capacity |

```erlang
{ok, _} = seki_shed:start_link(my_shed, #{
    target => 5,              %% target latency in ms
    interval => 100,          %% CoDel measurement interval
    max_in_flight => 1000,    %% absolute capacity
    p1_threshold => 90,       %% shed priority 1 at 90% utilization
    p2_threshold => 80,       %% shed priority 2 at 80%
    p3_threshold => 70        %% shed priority 3 at 70%
}).
```

### Usage

```erlang
%% Health check — always admitted
ok = seki_shed:admit(my_shed, 0).

%% Normal API request
case seki_shed:admit(my_shed, 2) of
    ok ->
        Start = erlang:monotonic_time(millisecond),
        Result = handle_request(),
        Duration = erlang:monotonic_time(millisecond) - Start,
        seki_shed:complete(my_shed, Duration),
        Result;
    {error, shed} ->
        {503, <<"Service overloaded">>}
end.

%% Background job — shed first
case seki_shed:admit(my_shed, 3) of
    ok -> process_job(), seki_shed:complete(my_shed, Duration);
    {error, shed} -> requeue_job()
end.
```

```elixir
case :seki_shed.admit(:my_shed, 2) do
  :ok ->
    start = :erlang.monotonic_time(:millisecond)
    result = handle_request()
    duration = :erlang.monotonic_time(:millisecond) - start
    :seki_shed.complete(:my_shed, duration)
    result
  {:error, :shed} ->
    send_resp(conn, 503, "overloaded")
end
```

### How CoDel Works

CoDel tracks how long requests spend "in the system" (sojourn time). When sojourn
time consistently exceeds the `target` for longer than `interval`, CoDel enters
dropping mode. In dropping mode, non-critical requests are rejected regardless of
utilization. When sojourn time drops below target, CoDel exits dropping mode.

This prevents bufferbloat — the case where a system appears to have capacity (queue
isn't full) but latency is unacceptable because every request is waiting behind a
long queue.

## Request Hedging

Reduces tail latency by spawning backup requests after a delay. The first successful
response wins; others are killed. Inspired by Google's
["The Tail at Scale"](https://research.google/pubs/the-tail-at-scale/) paper.

```erlang
case seki_hedge:race(fun() -> dns:resolve(Host) end, #{
    delay => 50,      %% wait 50ms before spawning backup
    max_extra => 1    %% spawn at most 1 backup
}) of
    {ok, Result} -> Result;
    {error, all_failed} -> {error, dns_failed}
end.
```

```elixir
case :seki_hedge.race(fn -> dns_resolve(host) end, %{delay: 50, max_extra: 1}) do
  {:ok, result} -> {:ok, result}
  {:error, :all_failed} -> {:error, :dns_failed}
end
```

### When to Use

- The operation is **idempotent** (safe to run twice)
- Tail latency matters more than throughput
- You have spare capacity to absorb extra requests
- The downstream service can handle the extra load

Typical use cases: DNS resolution, cache lookups across replicas, read-only database
queries to replicas, object storage reads.

### Named Hedging for Telemetry

```erlang
seki_hedge:race(dns_hedge, fun() -> dns:resolve(Host) end, #{
    delay => 50,
    max_extra => 2
}).
```

## Health Checking

Deep health checks with dependency aggregation and BEAM VM awareness. Three health
states: `healthy`, `degraded`, `unhealthy`.

### Setup

```erlang
{ok, _} = seki_health:start_link(app_health, #{
    vm_checks => true,       %% enable built-in VM checks
    check_interval => 10000  %% run checks every 10s
}).
```

Built-in VM checks (enabled by default):

- **vm_memory** — total memory usage, degrades above 4GB
- **vm_processes** — process count vs limit, unhealthy above 90%
- **vm_run_queue** — scheduler run queue depth, unhealthy above 10 per scheduler

### Registering Custom Checks

```erlang
%% Critical check — if this fails, the whole app is unhealthy
seki_health:register_check(app_health, database, fun() ->
    case db:ping() of
        ok -> {healthy, #{latency_ms => 2}};
        {error, Reason} -> {unhealthy, #{reason => Reason}}
    end
end, #{critical => true}).

%% Non-critical check — failure means degraded, not unhealthy
seki_health:register_check(app_health, cache, fun() ->
    case redis:ping() of
        ok -> {healthy, #{}};
        _ -> {unhealthy, #{reason => cache_down}}
    end
end).

%% Check that can return degraded
seki_health:register_check(app_health, search, fun() ->
    case search:status() of
        {ok, #{lag := Lag}} when Lag > 60 -> {degraded, #{lag => Lag}};
        {ok, _} -> {healthy, #{}};
        {error, _} -> {unhealthy, #{}}
    end
end, #{critical => false}).
```

```elixir
:seki_health.register_check(:app_health, :database, fn ->
  case MyApp.Repo.query("SELECT 1") do
    {:ok, _} -> {:healthy, %{}}
    _ -> {:unhealthy, %{reason: :db_down}}
  end
end, %{critical: true})
```

### Health Aggregation

Overall health is determined by aggregating all checks:

- If any **critical** check is unhealthy → overall is `unhealthy`
- If any non-critical check is unhealthy → overall is `degraded`
- If any check is degraded → overall is `degraded`
- Otherwise → `healthy`

### Kubernetes Probes

```erlang
%% Liveness: is the process alive and responsive? (VM-only)
ok = seki_health:liveness(app_health).

%% Readiness: are all dependencies healthy?
ok = seki_health:readiness(app_health).

%% Detailed status (for dashboards)
#{health := healthy, checks := CheckResults} = seki_health:check(app_health).
```

### Combining with Circuit Breakers

Use health checks to drive circuit breaker state:

```erlang
%% Register a check that monitors a circuit breaker
seki_health:register_check(app_health, payment_breaker, fun() ->
    case seki:state(payment_api) of
        closed -> {healthy, #{}};
        half_open -> {degraded, #{state => half_open}};
        open -> {unhealthy, #{state => open}}
    end
end, #{critical => false}).
```

## Deadline Propagation

Deadlines prevent requests from consuming resources after the caller has given up.
They propagate across service boundaries via HTTP headers and integrate with retry
to stop retrying when time is running out.

```erlang
%% Set a 5-second deadline
seki_deadline:set(5000).

%% Check before doing work
ok = seki_deadline:check().

%% Get remaining time
3200 = seki_deadline:time_remaining().

%% Run with automatic cleanup
{ok, Result} = seki_deadline:run(5000, fun() ->
    do_work()
end).
```

### Cross-Service Propagation

When calling another service, propagate the deadline:

```erlang
case seki_deadline:to_header() of
    {ok, Value} ->
        Headers = [{<<"x-deadline-remaining">>, Value}],
        httpc:request(get, {Url, Headers}, [], []);
    undefined ->
        httpc:request(get, {Url, []}, [], [])
end.
```

The receiving service picks it up:

```erlang
case cowboy_req:header(<<"x-deadline-remaining">>, Req) of
    undefined -> ok;
    Value -> seki_deadline:from_header(Value)
end.
```

### Integration with Retry

`seki_retry` automatically checks the deadline before each attempt and caps delays
to the remaining time. No additional configuration needed — just set a deadline
before calling retry:

```erlang
seki_deadline:set(10000),  %% 10s total budget
seki_retry:run(fun() ->
    external_api:call()
end, #{
    max_attempts => 5,
    backoff => exponential,
    base_delay => 100
}).
%% Retry will stop early if the deadline is reached
%% Delays are capped to remaining time
```
