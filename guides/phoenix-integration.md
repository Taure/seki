# Phoenix Integration

Seki works from Elixir with no wrapper needed — call the Erlang modules directly.
This guide shows how to integrate seki into a Phoenix application using Plugs,
contexts, and application setup.

## Application Setup

Initialize seki primitives in your `Application.start/2`:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    setup_seki()

    children = [
      MyApp.Repo,
      MyAppWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end

  defp setup_seki do
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
    {:ok, _} = :seki.new_breaker(:database, %{
      failure_threshold: 50,
      wait_duration: 30_000
    })

    {:ok, _} = :seki.new_breaker(:external_api, %{
      failure_threshold: 30,
      slow_call_duration: 5_000
    })

    # Bulkheads
    {:ok, _} = :seki_bulkhead.start_link(:payment_service, %{
      max_concurrent: 20
    })

    # Health checks
    {:ok, _} = :seki_health.start_link(:app_health, %{vm_checks: true})

    :seki_health.register_check(:app_health, :database, fn ->
      case MyApp.Repo.query("SELECT 1") do
        {:ok, _} -> {:healthy, %{}}
        _ -> {:unhealthy, %{reason: :db_down}}
      end
    end, %{critical: true})

    # OpenTelemetry
    :seki_otel.setup()
  end
end
```

## Rate Limiting Plug

```elixir
defmodule MyAppWeb.Plugs.RateLimit do
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
        |> put_status(429)
        |> Phoenix.Controller.json(%{error: "Rate limited", retry_after_ms: ms})
        |> halt()
    end
  end

  defp rate_limit_key(conn, opts) do
    case Keyword.get(opts, :by, :ip) do
      :ip ->
        conn.remote_ip |> :inet.ntoa() |> to_string()

      :user ->
        conn.assigns[:current_user] && conn.assigns.current_user.id

      :api_key ->
        Plug.Conn.get_req_header(conn, "x-api-key") |> List.first("anonymous")

      fun when is_function(fun, 1) ->
        fun.(conn)
    end
  end
end
```

## Deadline Plug

```elixir
defmodule MyAppWeb.Plugs.Deadline do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    default_timeout = Keyword.get(opts, :timeout, 30_000)

    case get_req_header(conn, "x-deadline-remaining") do
      [value] ->
        case :seki_deadline.from_header(value) do
          :ok -> :ok
          {:error, _} -> :seki_deadline.set(default_timeout)
        end

      [] ->
        :seki_deadline.set(default_timeout)
    end

    register_before_send(conn, fn conn ->
      :seki_deadline.clear()
      conn
    end)
  end
end
```

## Router Configuration

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug MyAppWeb.Plugs.Deadline, timeout: 30_000
    plug MyAppWeb.Plugs.RateLimit, limiter: :api_limit, by: :ip
  end

  pipeline :auth_api do
    plug :accepts, ["json"]
    plug MyAppWeb.Plugs.RateLimit, limiter: :auth_limit, by: :ip
  end

  scope "/api", MyAppWeb do
    pipe_through :api

    resources "/users", UserController, only: [:index, :show]
    resources "/posts", PostController
  end

  scope "/auth", MyAppWeb do
    pipe_through :auth_api

    post "/login", AuthController, :login
    post "/register", AuthController, :register
  end
end
```

## Circuit Breaker in Contexts

Use circuit breakers in your Phoenix contexts to protect external calls:

```elixir
defmodule MyApp.Accounts do
  def get_user_profile(user_id) do
    case :seki.call(:external_api, fn ->
      MyApp.ExternalAPI.fetch_profile(user_id)
    end) do
      {:ok, profile} ->
        {:ok, profile}

      {:error, :circuit_open} ->
        # Fall back to cached data
        case MyApp.Cache.get({:profile, user_id}) do
          nil -> {:error, :service_unavailable}
          cached -> {:ok, cached}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

## Retry in Contexts

```elixir
defmodule MyApp.Payments do
  def charge(params) do
    :seki_retry.run(:payment_retry, fn ->
      :seki.call(:payment_api, fn ->
        Stripe.Charge.create(params)
      end)
    end, %{
      max_attempts: 3,
      backoff: :exponential,
      base_delay: 200,
      max_delay: 5_000,
      jitter: :full,
      retry_on: fn
        {:error, {:http, status, _}} when status in [502, 503, 504] -> true
        {:error, :timeout} -> true
        _ -> false
      end
    })
  end
end
```

## Bulkhead for Expensive Operations

```elixir
defmodule MyApp.Reports do
  def generate(params) do
    case :seki_bulkhead.call(:report_gen, fn ->
      do_generate(params)
    end) do
      {:ok, report} -> {:ok, report}
      {:error, :bulkhead_full} -> {:error, :too_many_reports}
    end
  end
end
```

## Health Check Controller

```elixir
defmodule MyAppWeb.HealthController do
  use MyAppWeb, :controller

  def liveness(conn, _params) do
    case :seki_health.liveness(:app_health) do
      :ok -> json(conn, %{status: "ok"})
      {:error, _} -> conn |> put_status(503) |> json(%{status: "unhealthy"})
    end
  end

  def readiness(conn, _params) do
    case :seki_health.readiness(:app_health) do
      :ok -> json(conn, %{status: "ready"})
      {:error, _} -> conn |> put_status(503) |> json(%{status: "not ready"})
    end
  end

  def detailed(conn, _params) do
    status = :seki_health.check(:app_health)
    code = if status.health == :unhealthy, do: 503, else: 200
    conn |> put_status(code) |> json(status)
  end
end
```

```elixir
# In router.ex
scope "/health" do
  get "/live", MyAppWeb.HealthController, :liveness
  get "/ready", MyAppWeb.HealthController, :readiness
  get "/status", MyAppWeb.HealthController, :detailed
end
```

## Telemetry Integration

Attach to seki telemetry events alongside your existing Phoenix telemetry:

```elixir
defmodule MyApp.Telemetry do
  def attach do
    events = [
      [:seki, :breaker, :state_change],
      [:seki, :rate_limit, :deny],
      [:seki, :bulkhead, :rejected]
    ]

    :telemetry.attach_many("seki-events", events, &handle_event/4, %{})
  end

  defp handle_event([:seki, :breaker, :state_change], _measurements, metadata, _config) do
    require Logger
    Logger.warning("Circuit breaker #{metadata.name}: #{metadata.from} -> #{metadata.to}")
  end

  defp handle_event([:seki, :rate_limit, :deny], measurements, metadata, _config) do
    require Logger
    Logger.info("Rate limited #{metadata.name}/#{inspect(metadata.key)}, retry_after: #{measurements.retry_after}ms")
  end

  defp handle_event([:seki, :bulkhead, :rejected], _measurements, metadata, _config) do
    require Logger
    Logger.warning("Bulkhead #{metadata.name} full, request rejected")
  end
end
```

Call `MyApp.Telemetry.attach()` from your `Application.start/2`.
