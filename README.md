# Seki 堰

Resilience library for the BEAM — circuit breaking, rate limiting, bulkheads, and retry with telemetry and OpenTelemetry support.

Works natively from Erlang, Elixir, Gleam, and LFE.

## Features

- **Rate Limiting** — Token bucket, sliding window (Cloudflare-style), GCRA, leaky bucket
- **Circuit Breaker** — `gen_statem`-based with closed/open/half-open states, slow-call detection, custom error classifiers
- **Bulkhead** — Process-based concurrency limiter with atomics and automatic release on process death
- **Retry** — Composable retry with exponential/linear/constant backoff and full/equal/decorrelated jitter
- **Telemetry** — Events for every operation
- **OpenTelemetry** — Optional span events via `seki_otel`
- **Pluggable Backends** — ETS included, behaviour for custom backends (Redis, pg, etc.)

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

## Quick Start

### Rate Limiting

#### Erlang

```erlang
%% Create a rate limiter: 100 requests per minute, sliding window
ok = seki:new_limiter(api_limit, #{
    algorithm => sliding_window,
    limit => 100,
    window => timer:minutes(1)
}).

%% Check rate for a key
case seki:check(api_limit, UserId) of
    {allow, #{remaining := Remaining}} ->
        handle_request(Req);
    {deny, #{retry_after := Ms}} ->
        {429, #{<<"Retry-After">> => integer_to_binary(Ms div 1000)}, <<"Rate limited">>}
end.
```

#### Elixir

```elixir
# Create a rate limiter: 100 requests per minute, sliding window
:ok = :seki.new_limiter(:api_limit, %{
  algorithm: :sliding_window,
  limit: 100,
  window: :timer.minutes(1)
})

# Check rate for a key
case :seki.check(:api_limit, user_id) do
  {:allow, %{remaining: remaining}} ->
    handle_request(conn)
  {:deny, %{retry_after: ms}} ->
    conn |> put_status(429) |> json(%{error: "Rate limited", retry_after: ms})
end
```

### Circuit Breaker

#### Erlang

```erlang
%% Create a circuit breaker
{ok, _} = seki:new_breaker(db_pool, #{
    window_type => count,
    window_size => 20,
    failure_threshold => 50,     %% Trip at 50% failure rate
    slow_call_threshold => 80,   %% Trip at 80% slow call rate
    slow_call_duration => 2000,  %% Calls over 2s are "slow"
    wait_duration => 30000,      %% Wait 30s before half-open
    half_open_requests => 5      %% Allow 5 probes in half-open
}).

%% Use it
case seki:call(db_pool, fun() -> db:query(SQL) end) of
    {ok, Result} -> Result;
    {error, circuit_open} -> cached_result();
    {error, Reason} -> handle_error(Reason)
end.

%% Custom error classifier (only 5xx count as failures)
{ok, _} = seki:new_breaker(http_api, #{
    error_classifier => fun
        ({error, {http, Status, _}}) when Status >= 500 -> true;
        (_) -> false
    end
}).
```

#### Elixir

```elixir
# Create a circuit breaker
{:ok, _} = :seki.new_breaker(:db_pool, %{
  window_type: :count,
  window_size: 20,
  failure_threshold: 50,
  slow_call_duration: 2000,
  wait_duration: 30_000,
  half_open_requests: 5
})

# Use it
case :seki.call(:db_pool, fn -> Repo.all(User) end) do
  {:ok, users} -> users
  {:error, :circuit_open} -> cached_users()
  {:error, reason} -> handle_error(reason)
end
```

### Retry

#### Erlang

```erlang
Result = seki_retry:run(fun() ->
    httpc:request(get, {"https://api.example.com/data", []}, [], [])
end, #{
    max_attempts => 5,
    backoff => exponential,
    base_delay => 100,
    max_delay => 10000,
    jitter => full,
    retry_on => fun
        ({error, _}) -> true;
        ({ok, {{_, 503, _}, _, _}}) -> true;
        (_) -> false
    end
}).
```

#### Elixir

```elixir
result = :seki_retry.run(fn ->
  Req.get!("https://api.example.com/data")
end, %{
  max_attempts: 5,
  backoff: :exponential,
  base_delay: 100,
  max_delay: 10_000,
  jitter: :full,
  retry_on: fn
    {:error, _} -> true
    _ -> false
  end
})
```

### Bulkhead

#### Erlang

```erlang
%% Start a bulkhead allowing max 10 concurrent calls
{ok, _} = seki_bulkhead:start_link(external_api, #{max_concurrent => 10}).

%% Use it (automatically releases on return or crash)
case seki_bulkhead:call(external_api, fun() -> call_api() end) of
    {ok, Result} -> Result;
    {error, bulkhead_full} -> {503, <<"Service overloaded">>}
end.

%% Check status
#{current := 3, max := 10, available := 7} = seki_bulkhead:status(external_api).
```

### Combined Usage

```erlang
%% Rate limit -> Circuit breaker -> Your function
case seki:execute(db_breaker, api_limiter, fun() -> db:query(SQL) end) of
    {ok, Result} -> Result;
    {error, circuit_open} -> fallback();
    {error, {rate_limited, #{retry_after := Ms}}} -> rate_limited(Ms)
end.
```

## Nova Integration

### Rate Limiting Plugin

```erlang
-module(my_rate_limit_plugin).
-behaviour(nova_plugin).

-export([pre_request/2, post_request/2, plugin_info/0]).

pre_request(Req, Env) ->
    IP = cowboy_req:peer(Req),
    case seki:check(api_limit, IP) of
        {allow, #{remaining := Remaining}} ->
            Req2 = cowboy_req:set_resp_header(<<"X-RateLimit-Remaining">>,
                integer_to_binary(Remaining), Req),
            {ok, Req2, Env};
        {deny, #{retry_after := Ms}} ->
            Req2 = cowboy_req:set_resp_header(<<"Retry-After">>,
                integer_to_binary(Ms div 1000), Req),
            {stop, cowboy_req:reply(429, #{}, <<"Rate limited">>, Req2)}
    end.

post_request(Req, Env) ->
    {ok, Req, Env}.

plugin_info() ->
    #{name => <<"rate_limit">>, version => <<"0.1.0">>}.
```

### Circuit Breaker in Controller

```erlang
-module(my_controller).
-export([index/1]).

index(#{req := Req}) ->
    case seki:call(external_api, fun() -> fetch_data() end) of
        {ok, Data} ->
            {json, 200, #{}, Data};
        {error, circuit_open} ->
            {json, 503, #{}, #{error => <<"Service temporarily unavailable">>}};
        {error, _Reason} ->
            {json, 500, #{}, #{error => <<"Internal error">>}}
    end.
```

### Application Setup

```erlang
-module(my_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    %% Rate limiters
    ok = seki:new_limiter(api_limit, #{
        algorithm => sliding_window,
        limit => 1000,
        window => timer:minutes(1)
    }),
    ok = seki:new_limiter(auth_limit, #{
        algorithm => token_bucket,
        limit => 5,
        window => timer:minutes(1),
        burst => 5
    }),
    %% Circuit breakers
    {ok, _} = seki:new_breaker(external_api, #{
        failure_threshold => 50,
        wait_duration => 30000
    }),
    %% Bulkheads
    {ok, _} = seki_bulkhead:start_link(payment_service, #{max_concurrent => 20}),
    %% OTel integration
    seki_otel:setup(),
    my_sup:start_link().

stop(_State) -> ok.
```

## Phoenix Integration

### Rate Limiting Plug

```elixir
defmodule MyAppWeb.RateLimitPlug do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    limiter = Keyword.fetch!(opts, :limiter)
    key = rate_limit_key(conn, opts)

    case :seki.check(limiter, key) do
      {:allow, %{remaining: remaining}} ->
        conn
        |> put_resp_header("x-ratelimit-remaining", to_string(remaining))

      {:deny, %{retry_after: ms}} ->
        conn
        |> put_resp_header("retry-after", to_string(div(ms, 1000)))
        |> send_resp(429, Jason.encode!(%{error: "Rate limited"}))
        |> halt()
    end
  end

  defp rate_limit_key(conn, opts) do
    case Keyword.get(opts, :by, :ip) do
      :ip -> to_string(:inet.ntoa(conn.remote_ip))
      :user -> conn.assigns[:current_user] && conn.assigns.current_user.id
      fun when is_function(fun, 1) -> fun.(conn)
    end
  end
end
```

### Router Usage

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug MyAppWeb.RateLimitPlug, limiter: :api_limit, by: :ip
  end

  pipeline :auth_api do
    plug :accepts, ["json"]
    plug MyAppWeb.RateLimitPlug, limiter: :auth_limit, by: :ip
  end

  scope "/api", MyAppWeb do
    pipe_through :api
    resources "/users", UserController
  end

  scope "/auth", MyAppWeb do
    pipe_through :auth_api
    post "/login", AuthController, :login
  end
end
```

### Circuit Breaker in Context

```elixir
defmodule MyApp.ExternalAPI do
  def fetch_user(id) do
    case :seki.call(:external_api, fn ->
      Req.get!("https://api.example.com/users/#{id}")
    end) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, :circuit_open} -> {:error, :service_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

### Application Setup

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    # Rate limiters
    :ok = :seki.new_limiter(:api_limit, %{
      algorithm: :sliding_window,
      limit: 1000,
      window: :timer.minutes(1)
    })

    :ok = :seki.new_limiter(:auth_limit, %{
      algorithm: :token_bucket,
      limit: 5,
      window: :timer.minutes(1),
      burst: 5
    })

    # Circuit breakers
    {:ok, _} = :seki.new_breaker(:external_api, %{
      failure_threshold: 50,
      wait_duration: 30_000
    })

    # OTel integration
    :seki_otel.setup()

    children = [
      # ...
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
end
```

## Algorithms

### Rate Limiting

| Algorithm | Best For | Memory | Burst Handling |
|-----------|----------|--------|----------------|
| `sliding_window` | General purpose (default) | 2 counters/key | Prevents boundary bursts |
| `token_bucket` | APIs with burst allowance | 2 values/key | Controlled bursts |
| `gcra` | High-performance, minimal state | 1 timestamp/key | Configurable tolerance |
| `leaky_bucket` | Traffic shaping, smooth output | 2 values/key | No bursts |

### Circuit Breaker States

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

## Telemetry Events

All events use the `[seki, ...]` prefix:

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[seki, rate_limit, allow]` | `remaining`, `cost` | `name`, `key` |
| `[seki, rate_limit, deny]` | `retry_after`, `cost` | `name`, `key` |
| `[seki, breaker, call]` | `duration` | `name`, `state`, `outcome` |
| `[seki, breaker, state_change]` | `system_time` | `name`, `from`, `to` |
| `[seki, retry, attempt]` | `attempt` | `name` |
| `[seki, retry, retry]` | `attempt`, `delay` | `name`, `error` |
| `[seki, retry, success]` | `attempt` | `name` |
| `[seki, retry, exhausted]` | `attempts` | `name`, `error` |
| `[seki, bulkhead, acquire]` | `current`, `available` | `name` |
| `[seki, bulkhead, rejected]` | `current`, `available` | `name` |

## OpenTelemetry

```erlang
%% Erlang
seki_otel:setup().
```

```elixir
# Elixir
:seki_otel.setup()
```

This attaches to all seki telemetry events and adds span events to the current OTel trace context. Circuit breaker state changes, rate limit denials, retry attempts, and bulkhead rejections all appear as events on the active span.

## License

Apache-2.0
