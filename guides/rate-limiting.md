# Rate Limiting

Seki provides four rate limiting algorithms, each with different trade-offs for burst
handling, memory usage, and accuracy.

## Algorithms

| Algorithm | Best For | Burst Handling | Memory |
|-----------|----------|----------------|--------|
| `sliding_window` | General purpose | Prevents boundary bursts | 2 counters/key |
| `token_bucket` | APIs with burst allowance | Controlled bursts up to burst size | 2 values/key |
| `gcra` | High-performance, minimal state | Configurable tolerance | 1 timestamp/key |
| `leaky_bucket` | Traffic shaping, smooth output | No bursts allowed | 2 values/key |

## Sliding Window

The default algorithm. Uses Cloudflare-style two-window interpolation to prevent
burst at window boundaries.

```erlang
ok = seki:new_limiter(api_limit, #{
    algorithm => sliding_window,
    limit => 100,
    window => timer:minutes(1)
}).
```

With a fixed window counter, a client could send 100 requests at 0:59 and another 100
at 1:01 — 200 requests in 2 seconds. Sliding window interpolates between the current
and previous window to prevent this.

## Token Bucket

Allows controlled bursts up to a configurable burst size. Tokens refill at a steady rate.

```erlang
ok = seki:new_limiter(api_limit, #{
    algorithm => token_bucket,
    limit => 100,         %% refill rate: 100 per window
    window => timer:minutes(1),
    burst => 20           %% allow up to 20 requests in a burst
}).
```

A freshly created bucket starts with `burst` tokens. Use this when you want to allow
short bursts (e.g., page loads that trigger several API calls) while enforcing a
steady-state rate.

## GCRA (Generic Cell Rate Algorithm)

Minimal state — stores only a single timestamp per key. Used by telecom networks
and CDNs for its simplicity and precision.

```erlang
ok = seki:new_limiter(cdn_limit, #{
    algorithm => gcra,
    limit => 1000,
    window => timer:seconds(1)
}).
```

## Leaky Bucket

Smooths traffic into a steady output rate. Requests that arrive too fast are rejected.
No bursts are allowed.

```erlang
ok = seki:new_limiter(outbound_limit, #{
    algorithm => leaky_bucket,
    limit => 50,
    window => timer:seconds(1)
}).
```

Use this for shaping outbound traffic to an external API with strict rate limits.

## Multi-Cost Requests

Some operations consume more capacity than others. Use the cost parameter to
weight requests accordingly:

```erlang
%% A search query costs 5 tokens
case seki:check(api_limit, UserId, 5) of
    {allow, #{remaining := Remaining}} -> do_search();
    {deny, #{retry_after := Ms}} -> rate_limited(Ms)
end.

%% A simple read costs 1 token (default)
case seki:check(api_limit, UserId) of
    {allow, _} -> do_read();
    {deny, _} -> rate_limited()
end.
```

## Inspecting Without Consuming

Use `inspect/2,3` to check the current state without consuming tokens. Useful for
displaying rate limit information or making routing decisions:

```erlang
case seki:inspect(api_limit, UserId) of
    {allow, #{remaining := R}} when R < 10 ->
        logger:info("User ~p approaching rate limit: ~p remaining", [UserId, R]);
    {deny, _} ->
        logger:warning("User ~p is rate limited", [UserId]);
    _ ->
        ok
end.
```

## Per-Key Rate Limiting

The second argument to `check/2` is the key. Use it to rate limit by user, IP,
API key, or any other dimension:

```erlang
%% Per user
seki:check(api_limit, UserId).

%% Per IP
seki:check(api_limit, ClientIP).

%% Per API key + endpoint
seki:check(api_limit, {ApiKey, "/search"}).
```

## Resetting and Cleanup

```erlang
%% Reset a specific key (e.g., after a user upgrades their plan)
seki:reset(api_limit, UserId).

%% Delete a limiter entirely
seki:delete_limiter(api_limit).
```

## Distributed Rate Limiting

For multi-node deployments, use the `pg`-based backend for eventually consistent
distributed rate limiting:

```erlang
ok = seki:new_limiter(api_limit, #{
    algorithm => sliding_window,
    limit => 1000,
    window => timer:minutes(1),
    backend => seki_backend_pg,
    backend_opts => #{
        scope => seki_pg,
        group => api_limiters,
        gossip_interval => 1000  %% broadcast every second
    }
}).
```

Each node maintains local state and periodically gossips with peers via Erlang's
`pg` module. Merges are algorithm-aware:

- Sliding window: takes the maximum count (conservative)
- Token bucket: takes the lower token count (conservative)
- GCRA: takes the higher TAT timestamp

This is eventually consistent — under normal conditions, rate limits converge within
one gossip interval. During partitions, each node enforces its local view independently.

## Telemetry Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[seki, rate_limit, allow]` | `remaining`, `cost` | `name`, `key` |
| `[seki, rate_limit, deny]` | `retry_after`, `cost` | `name`, `key` |

## Custom Backends

Implement the `seki_backend` behaviour to store rate limit state in Redis, Mnesia,
or any other store:

```erlang
-module(my_redis_backend).
-behaviour(seki_backend).

-export([init/1, read/2, write/3, delete/2]).

init(Opts) ->
    {ok, Opts}.

read(State, Key) ->
    %% Read from Redis
    ...

write(State, Key, Value) ->
    %% Write to Redis
    ...

delete(State, Key) ->
    %% Delete from Redis
    ...
```
