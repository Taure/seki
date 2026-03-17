# Nova Integration

Seki integrates with [Nova](https://github.com/novaframework/nova) through the
plugin system. Rate limiting, deadline propagation, and circuit breaking fit
naturally into Nova's pre/post request pipeline.

## Application Setup

Initialize seki primitives in your application startup, before Nova starts serving
requests:

```erlang
-module(my_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    setup_rate_limiters(),
    setup_breakers(),
    setup_bulkheads(),
    seki_otel:setup(),
    my_sup:start_link().

stop(_State) -> ok.

setup_rate_limiters() ->
    %% General API: 1000 req/min per IP
    ok = seki:new_limiter(api_limit, #{
        algorithm => sliding_window,
        limit => 1000,
        window => timer:minutes(1)
    }),
    %% Auth endpoints: 5 req/min per IP (strict)
    ok = seki:new_limiter(auth_limit, #{
        algorithm => token_bucket,
        limit => 5,
        window => timer:minutes(1),
        burst => 5
    }),
    %% Webhook delivery: smooth outbound rate
    ok = seki:new_limiter(webhook_limit, #{
        algorithm => leaky_bucket,
        limit => 50,
        window => timer:seconds(1)
    }).

setup_breakers() ->
    {ok, _} = seki:new_breaker(database, #{
        failure_threshold => 50,
        wait_duration => 30000
    }),
    {ok, _} = seki:new_breaker(external_api, #{
        failure_threshold => 30,
        slow_call_duration => 5000,
        wait_duration => 60000
    }).

setup_bulkheads() ->
    {ok, _} = seki_bulkhead:start_link(payment_service, #{
        max_concurrent => 20
    }).
```

## Rate Limiting Plugin

Nova plugins intercept requests before they reach your controllers. A rate limiting
plugin checks seki before allowing the request through:

```erlang
-module(seki_rate_limit_plugin).
-behaviour(nova_plugin).

-export([pre_request/4, post_request/4, plugin_info/0]).

pre_request(Req, _Env, Opts, State) ->
    Limiter = maps:get(limiter, Opts, api_limit),
    Key = rate_limit_key(Req, Opts),
    case seki:check(Limiter, Key) of
        {allow, #{remaining := Remaining}} ->
            Req2 = cowboy_req:set_resp_header(
                <<"x-ratelimit-remaining">>,
                integer_to_binary(Remaining), Req),
            {ok, Req2, State};
        {deny, #{retry_after := Ms}} ->
            Req2 = cowboy_req:set_resp_header(
                <<"retry-after">>,
                integer_to_binary(Ms div 1000), Req),
            Body = jsx:encode(#{error => <<"Rate limited">>,
                                retry_after_ms => Ms}),
            {stop, {reply, 429, #{<<"content-type">> => <<"application/json">>},
                    Body}, Req2, State}
    end.

post_request(Req, _Env, _Opts, State) ->
    {ok, Req, State}.

plugin_info() ->
    #{title => <<"Seki Rate Limit">>,
      version => <<"0.1.0">>,
      description => <<"Rate limiting plugin for Nova using Seki">>}.

%% Internal

rate_limit_key(Req, Opts) ->
    case maps:get(key, Opts, ip) of
        ip ->
            {IP, _Port} = cowboy_req:peer(Req),
            IP;
        {header, Name} ->
            cowboy_req:header(Name, Req, <<"anonymous">>);
        Fun when is_function(Fun, 1) ->
            Fun(Req)
    end.
```

## Deadline Plugin

Propagates deadlines from upstream services. If a request arrives with an
`x-deadline-remaining` header, seki picks up the upstream deadline. Otherwise,
it sets a default timeout. This integrates with `seki_retry` to stop retrying
when time is running out:

```erlang
-module(seki_deadline_plugin).
-behaviour(nova_plugin).

-export([pre_request/4, post_request/4, plugin_info/0]).

pre_request(Req, _Env, Opts, State) ->
    DefaultTimeout = maps:get(timeout, Opts, 30000),
    case cowboy_req:header(<<"x-deadline-remaining">>, Req) of
        undefined ->
            seki_deadline:set(DefaultTimeout);
        Value ->
            case seki_deadline:from_header(Value) of
                ok -> ok;
                {error, _} -> seki_deadline:set(DefaultTimeout)
            end
    end,
    {ok, Req, State}.

post_request(Req, _Env, _Opts, State) ->
    seki_deadline:clear(),
    {ok, Req, State}.

plugin_info() ->
    #{title => <<"Seki Deadline">>,
      version => <<"0.1.0">>,
      description => <<"Deadline propagation plugin for Nova">>}.
```

## Route Configuration

Apply plugins to route groups with different settings per group:

```erlang
#{prefix => "/api",
  plugins => [
      {pre_request, seki_deadline_plugin, #{timeout => 30000}},
      {pre_request, seki_rate_limit_plugin, #{limiter => api_limit}}
  ],
  routes => [
      {"/users", {user_controller, index}, #{methods => [get]}},
      {"/users/:id", {user_controller, show}, #{methods => [get]}}
  ]
}.

%% Stricter limits for auth endpoints
#{prefix => "/auth",
  plugins => [
      {pre_request, seki_rate_limit_plugin, #{
          limiter => auth_limit,
          key => ip
      }}
  ],
  routes => [
      {"/login", {auth_controller, login}, #{methods => [post]}},
      {"/register", {auth_controller, register}, #{methods => [post]}}
  ]
}.

%% Internal/admin endpoints with per-API-key limiting
#{prefix => "/admin",
  security => #{module => admin_security},
  plugins => [
      {pre_request, seki_rate_limit_plugin, #{
          limiter => admin_limit,
          key => {header, <<"x-api-key">>}
      }}
  ],
  routes => [
      {"/stats", {admin_controller, stats}, #{methods => [get]}}
  ]
}.
```

## Circuit Breaker in Controllers

Use circuit breakers in your controllers to protect calls to external services:

```erlang
-module(user_controller).
-export([index/1, show/1]).

index(#{req := _Req}) ->
    case seki:call(database, fun() -> db:query("SELECT * FROM users") end) of
        {ok, Users} ->
            {json, 200, #{}, #{users => Users}};
        {error, circuit_open} ->
            {json, 503, #{}, #{error => <<"Database temporarily unavailable">>}};
        {error, _Reason} ->
            {json, 500, #{}, #{error => <<"Internal error">>}}
    end.

show(#{req := _Req, params := #{<<"id">> := Id}}) ->
    case seki:call(external_api, fun() -> fetch_user_details(Id) end) of
        {ok, Details} ->
            {json, 200, #{}, Details};
        {error, circuit_open} ->
            %% Return cached/partial data when the API is down
            case cache:get({user, Id}) of
                {ok, Cached} -> {json, 200, #{}, Cached};
                miss -> {json, 503, #{}, #{error => <<"Service unavailable">>}}
            end;
        {error, Reason} ->
            logger:error("Failed to fetch user ~p: ~p", [Id, Reason]),
            {json, 502, #{}, #{error => <<"Upstream error">>}}
    end.
```

## Bulkhead in Controllers

Limit concurrent calls to expensive operations:

```erlang
-module(report_controller).
-export([generate/1]).

generate(#{req := _Req, params := Params}) ->
    case seki_bulkhead:call(report_gen, fun() ->
        reports:generate(Params)
    end) of
        {ok, Report} ->
            {json, 200, #{}, Report};
        {error, bulkhead_full} ->
            {json, 503, #{}, #{
                error => <<"Too many reports generating, try again later">>
            }}
    end.
```

## Retry with Deadline in Controllers

Combine retry and deadline for resilient external calls:

```erlang
-module(payment_controller).
-export([charge/1]).

charge(#{req := _Req, body := Body}) ->
    %% Deadline was set by the plugin — retry respects it automatically
    case seki_retry:run(payment_retry, fun() ->
        seki:call(payment_api, fun() ->
            payment_gateway:charge(Body)
        end)
    end, #{
        max_attempts => 3,
        backoff => exponential,
        base_delay => 200,
        retry_on => fun
            ({error, {http, 503, _}}) -> true;
            ({error, timeout}) -> true;
            (_) -> false
        end
    }) of
        {ok, {ok, Receipt}} ->
            {json, 200, #{}, Receipt};
        {ok, {error, circuit_open}} ->
            {json, 503, #{}, #{error => <<"Payment service unavailable">>}};
        {error, _} ->
            {json, 502, #{}, #{error => <<"Payment failed">>}}
    end.
```

## Health Check Endpoint

Expose seki health checks via a Nova controller for Kubernetes probes:

```erlang
-module(health_controller).
-export([liveness/1, readiness/1]).

liveness(#{req := _Req}) ->
    case seki_health:liveness(app_health) of
        ok -> {json, 200, #{}, #{status => <<"ok">>}};
        {error, _} -> {json, 503, #{}, #{status => <<"unhealthy">>}}
    end.

readiness(#{req := _Req}) ->
    case seki_health:readiness(app_health) of
        ok -> {json, 200, #{}, #{status => <<"ready">>}};
        {error, _} -> {json, 503, #{}, #{status => <<"not ready">>}}
    end.
```

```erlang
%% Routes
#{prefix => "/health",
  routes => [
      {"/live", {health_controller, liveness}, #{methods => [get]}},
      {"/ready", {health_controller, readiness}, #{methods => [get]}}
  ]
}.
```
