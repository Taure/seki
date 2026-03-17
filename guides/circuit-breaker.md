# Circuit Breaker

Seki's circuit breaker is a `gen_statem` with three states: **closed**, **open**, and
**half_open**. It tracks failure and slow-call rates in a sliding window and opens
when thresholds are exceeded.

```
              failure threshold exceeded
  [CLOSED] ───────────────────────────────> [OPEN]
     ^                                        │
     │                                        │ wait_duration expires
     │ all probes succeed                     v
     └──────────────── [HALF_OPEN] <──────────┘
                           │
                           │ any probe fails
                           └──────────> [OPEN]
```

## Creating a Breaker

```erlang
{ok, _} = seki:new_breaker(db_pool, #{
    window_type => count,
    window_size => 20,
    failure_threshold => 50,
    slow_call_threshold => 80,
    slow_call_duration => 2000,
    wait_duration => 30000,
    half_open_requests => 5
}).
```

```elixir
{:ok, _} = :seki.new_breaker(:db_pool, %{
  window_type: :count,
  window_size: 20,
  failure_threshold: 50,
  slow_call_threshold: 80,
  slow_call_duration: 2000,
  wait_duration: 30_000,
  half_open_requests: 5
})
```

## Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `window_type` | `count` | `count` (last N calls) or `time` (last N ms) |
| `window_size` | `20` | Number of calls or milliseconds for the window |
| `failure_threshold` | `50` | Percentage (1-100) of failures to trip the breaker |
| `slow_call_threshold` | `80` | Percentage (1-100) of slow calls to trip |
| `slow_call_duration` | `2000` | Calls taking longer than this (ms) are "slow" |
| `wait_duration` | `30000` | Time in open state before trying half-open (ms) |
| `half_open_requests` | `5` | Number of probe requests allowed in half-open |
| `error_classifier` | matches `{error, _}` | Function that decides what counts as a failure |

## Window Types

### Count-Based Window

Tracks the last N calls. Simple, predictable, and the default.

```erlang
{ok, _} = seki:new_breaker(my_service, #{
    window_type => count,
    window_size => 20   %% track last 20 calls
}).
```

The breaker requires at least 5 outcomes before it can trip, preventing false positives
during startup.

### Time-Based Window

Tracks all calls within the last N milliseconds. Better for services with variable
traffic patterns.

```erlang
{ok, _} = seki:new_breaker(my_service, #{
    window_type => time,
    window_size => 60000   %% track calls from last 60 seconds
}).
```

Old entries are pruned automatically on each call.

## Error Classifiers

By default, the breaker treats any `{error, _}` or thrown error as a failure.
Use a custom classifier to be more selective:

```erlang
%% Only count 5xx HTTP errors as failures
{ok, _} = seki:new_breaker(http_api, #{
    error_classifier => fun
        ({error, {http, Status, _}}) when Status >= 500 -> true;
        (_) -> false
    end
}).
```

```elixir
{:ok, _} = :seki.new_breaker(:http_api, %{
  error_classifier: fn
    {:error, {:http, status, _}} when status >= 500 -> true
    _ -> false
  end
})
```

This is useful when 4xx errors (client mistakes) should not count against the service
health, while 5xx errors (service failures) should.

## Slow Call Detection

The breaker tracks calls that take longer than `slow_call_duration`. When the
combined rate of errors and slow calls exceeds `slow_call_threshold`, the breaker trips.

This catches degraded services that are technically responding but too slowly to be useful:

```erlang
{ok, _} = seki:new_breaker(search_service, #{
    slow_call_duration => 1000,   %% anything over 1s is "slow"
    slow_call_threshold => 60,    %% trip at 60% slow+error rate
    failure_threshold => 30       %% trip at 30% pure error rate
}).
```

## Half-Open State

When the breaker opens, it waits `wait_duration` milliseconds then transitions to
half-open. In half-open:

- Up to `half_open_requests` probe calls are allowed through
- If all probes succeed, the breaker closes
- If any probe fails, the breaker re-opens and the wait timer resets

This prevents a thundering herd from hitting a recovering service.

## Inspecting and Resetting

```erlang
%% Check current state
closed = seki:state(db_pool).

%% Force reset to closed (e.g., after a manual fix)
ok = seki:reset_breaker(db_pool).

%% Delete and stop the breaker process
ok = seki:delete_breaker(db_pool).
```

## One Breaker Per Dependency

Create separate breakers for each external dependency. This prevents a failing
database from opening the breaker for your payment provider:

```erlang
start(_Type, _Args) ->
    {ok, _} = seki:new_breaker(database, #{failure_threshold => 50}),
    {ok, _} = seki:new_breaker(payment_api, #{
        failure_threshold => 30,
        slow_call_duration => 5000
    }),
    {ok, _} = seki:new_breaker(email_service, #{
        failure_threshold => 70,
        wait_duration => 60000
    }),
    my_sup:start_link().
```

## Telemetry Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[seki, breaker, call]` | `duration` | `name`, `state`, `outcome` |
| `[seki, breaker, state_change]` | `system_time` | `name`, `from`, `to` |

Monitor state changes to alert your team when a breaker trips:

```erlang
telemetry:attach(<<"breaker-alert">>, [seki, breaker, state_change], fun
    (_Event, _Measurements, #{name := Name, to := open}, _Config) ->
        alert:send("Circuit breaker ~p opened", [Name]);
    (_, _, _, _) ->
        ok
end, #{}).
```
