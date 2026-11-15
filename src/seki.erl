-module(seki).

-moduledoc """
Main API for Seki resilience primitives.

Provides rate limiting with four algorithms (token bucket, sliding window, GCRA,
leaky bucket), circuit breaking with configurable failure/slow-call thresholds,
and a combined `execute/3` that checks rate limits before calling through a breaker.

## Erlang

    seki:new_limiter(my_api, #{algorithm => sliding_window, limit => 100, window => 60000}).
    seki:check(my_api, UserId).

## Elixir

    :seki.new_limiter(:my_api, %{algorithm: :sliding_window, limit: 100, window: 60_000})
    :seki.check(:my_api, user_id)

## Names

A limiter, breaker, bulkhead, load shedder, adaptive limiter or health checker
is named by any term (`t:name/0`). An atom is the usual name. Use another term
when there is one per tenant, worker or host, so that no atom is created for
each:

    seki:new_breaker({payments, TenantId}, #{}).
    seki:call({payments, TenantId}, fun() -> charge(TenantId) end).

A process named by an atom is registered under it, as `whereis/1` shows. One
named by any other term is found through seki only.

A tuple is always a name on this node. `{Name, Node}` is not read as the
process `Name` on `Node`: to use a breaker on another node, call that node.

A pid is not a name: `new_breaker/2` and the other `new_*` functions return
`{error, {invalid_name, Pid}}` for one. The pid they return is accepted in
place of the name by every function that calls the process.

## Options

`new_breaker/2` and the other `new_*` functions check their options before
they start anything. An option of the wrong kind, such as
`window_size => 0`, returns `{error, {invalid_option, window_size}}`, and
options that are not a map return `{error, invalid_options}`. A key that seki
does not know is ignored.
""".

%% Rate limiter API
-export([
    new_limiter/2,
    check/2,
    check/3,
    inspect/2,
    inspect/3,
    reset/2,
    delete_limiter/1
]).

%% Circuit breaker API
-export([
    new_breaker/2,
    call/2,
    call/3,
    state/1,
    reset_breaker/1,
    delete_breaker/1
]).

%% Supervised process API
-export([
    new_bulkhead/2,
    delete_bulkhead/1,
    new_adaptive/2,
    delete_adaptive/1,
    new_shed/2,
    delete_shed/1,
    new_health/2,
    delete_health/1
]).

%% Combined API
-export([
    execute/3
]).

%%----------------------------------------------------------------------
%% Types
%%----------------------------------------------------------------------

-doc """
The name of a limiter, breaker, bulkhead, load shedder, adaptive limiter or
health checker: any term but a pid.
""".
-type name() :: term().
-type limiter_name() :: name().
-type breaker_name() :: name().
-type key() :: term().

-type algorithm() :: token_bucket | sliding_window | gcra | leaky_bucket.

-type limiter_opts() :: #{
    algorithm := algorithm(),
    limit := pos_integer(),
    window := pos_integer(),
    burst => pos_integer(),
    backend => module(),
    backend_opts => map(),
    allow_non_atomic => boolean()
}.

-type breaker_opts() :: #{
    window_type => count | time,
    window_size => pos_integer(),
    failure_threshold => 1..100,
    slow_call_threshold => 1..100,
    slow_call_duration => pos_integer(),
    wait_duration => pos_integer(),
    half_open_requests => pos_integer(),
    error_classifier => fun((term()) -> boolean())
}.

-type check_result() ::
    {allow, #{remaining := non_neg_integer(), reset := non_neg_integer()}}
    | {deny, #{retry_after := non_neg_integer()}}.

-type call_result() ::
    {ok, term()}
    | {error, circuit_open}
    | {error, term()}.

-export_type([
    name/0,
    limiter_name/0,
    breaker_name/0,
    key/0,
    algorithm/0,
    limiter_opts/0,
    breaker_opts/0,
    check_result/0,
    call_result/0
]).

%%----------------------------------------------------------------------
%% Rate Limiter API
%%----------------------------------------------------------------------

-doc """
Create a new rate limiter with the given algorithm and options.

Returns `{error, already_registered}` if the name is taken, and
`{error, {backend_not_atomic, Backend}}` if `backend` does not export
`atomic_update/3`. Such a backend checks with `get/2` then `put/3`, so
concurrent checks of one key can exceed the limit; pass
`allow_non_atomic => true` to use it anyway.
""".
-spec new_limiter(limiter_name(), limiter_opts()) -> ok | {error, term()}.
new_limiter(Name, Opts) ->
    seki_limiter_registry:register(Name, Opts).

-doc "Check if a request is allowed for the given key (cost = 1).".
-spec check(limiter_name(), key()) -> check_result().
check(Name, Key) ->
    check(Name, Key, 1).

-doc """
Check if a request with a custom cost is allowed for the given key.

Raises `{limiter_not_found, Name}` if no limiter has this name.
""".
-spec check(limiter_name(), key(), pos_integer()) -> check_result().
check(Name, Key, Cost) ->
    {Algorithm, Backend, BackendState, Config} = seki_limiter_registry:lookup(Name),
    Now = erlang:monotonic_time(millisecond),
    Result = seki_algorithm:check(Algorithm, Backend, BackendState, Key, Cost, Now, Config),
    emit_check_telemetry(Name, Key, Cost, Result),
    Result.

-doc "Non-destructive check — read current state without consuming tokens.".
-spec inspect(limiter_name(), key()) -> check_result().
inspect(Name, Key) ->
    inspect(Name, Key, 1).

-doc "Non-destructive check with a custom cost.".
-spec inspect(limiter_name(), key(), pos_integer()) -> check_result().
inspect(Name, Key, Cost) ->
    {Algorithm, Backend, BackendState, Config} = seki_limiter_registry:lookup(Name),
    Now = erlang:monotonic_time(millisecond),
    seki_algorithm:inspect(Algorithm, Backend, BackendState, Key, Cost, Now, Config).

-doc "Reset the rate limit state for a key.".
-spec reset(limiter_name(), key()) -> ok.
reset(Name, Key) ->
    {_Algorithm, Backend, BackendState, _Config} = seki_limiter_registry:lookup(Name),
    Backend:delete(BackendState, Key).

-doc "Delete a rate limiter and clean up its backend state.".
-spec delete_limiter(limiter_name()) -> ok.
delete_limiter(Name) ->
    seki_limiter_registry:unregister(Name).

%%----------------------------------------------------------------------
%% Circuit Breaker API
%%----------------------------------------------------------------------

-doc "Create a new circuit breaker with the given options.".
-spec new_breaker(breaker_name(), breaker_opts()) -> {ok, pid()} | {error, term()}.
new_breaker(Name, Opts) ->
    seki_breaker_sup:start_breaker(Name, Opts).

-doc "Execute a function through a circuit breaker.".
-spec call(breaker_name(), fun(() -> term())) -> call_result().
call(Name, Fun) ->
    call(Name, Fun, #{}).

-doc """
Execute a function through a circuit breaker with options.

Exits with `{noproc, _}` if no breaker has this name. `Fun` is not run.
""".
-spec call(breaker_name(), fun(() -> term()), map()) -> call_result().
call(Name, Fun, CallOpts) ->
    seki_breaker:call(Name, Fun, CallOpts).

-doc "Get the current state of a circuit breaker.".
-spec state(breaker_name()) -> closed | open | half_open.
state(Name) ->
    seki_breaker:get_state(Name).

-doc "Reset a circuit breaker to closed state.".
-spec reset_breaker(breaker_name()) -> ok.
reset_breaker(Name) ->
    seki_breaker:reset(Name).

-doc "Delete a circuit breaker and stop its process.".
-spec delete_breaker(breaker_name()) -> ok | {error, term()}.
delete_breaker(Name) ->
    seki_breaker_sup:stop_breaker(Name).

%%----------------------------------------------------------------------
%% Supervised Process API
%%----------------------------------------------------------------------

-doc "Start a supervised bulkhead.".
-spec new_bulkhead(name(), map()) -> {ok, pid()} | {error, term()}.
new_bulkhead(Name, Opts) ->
    seki_process_sup:start_child(seki_bulkhead, Name, Opts).

-doc "Stop and remove a supervised bulkhead.".
-spec delete_bulkhead(name()) -> ok | {error, term()}.
delete_bulkhead(Name) ->
    seki_process_sup:stop_child(Name).

-doc "Start a supervised adaptive concurrency limiter.".
-spec new_adaptive(name(), map()) -> {ok, pid()} | {error, term()}.
new_adaptive(Name, Opts) ->
    seki_process_sup:start_child(seki_adaptive, Name, Opts).

-doc "Stop and remove a supervised adaptive concurrency limiter.".
-spec delete_adaptive(name()) -> ok | {error, term()}.
delete_adaptive(Name) ->
    seki_process_sup:stop_child(Name).

-doc "Start a supervised load shedder.".
-spec new_shed(name(), map()) -> {ok, pid()} | {error, term()}.
new_shed(Name, Opts) ->
    seki_process_sup:start_child(seki_shed, Name, Opts).

-doc "Stop and remove a supervised load shedder.".
-spec delete_shed(name()) -> ok | {error, term()}.
delete_shed(Name) ->
    seki_process_sup:stop_child(Name).

-doc "Start a supervised health checker.".
-spec new_health(name(), map()) -> {ok, pid()} | {error, term()}.
new_health(Name, Opts) ->
    seki_process_sup:start_child(seki_health, Name, Opts).

-doc "Stop and remove a supervised health checker.".
-spec delete_health(name()) -> ok | {error, term()}.
delete_health(Name) ->
    seki_process_sup:stop_child(Name).

%%----------------------------------------------------------------------
%% Combined API
%%----------------------------------------------------------------------

-doc """
Check rate limit then execute through circuit breaker. Returns `{error, {rate_limited, Info}}` if denied.

Raises as `check/3` and `call/3` do for a limiter or breaker that does not
exist. `Fun` is not run.
""".
-spec execute(breaker_name(), limiter_name(), fun(() -> term())) ->
    call_result() | {error, rate_limited}.
execute(Breaker, Limiter, Fun) ->
    case check(Limiter, default) of
        {allow, _} ->
            call(Breaker, Fun);
        {deny, Info} ->
            emit_denied_telemetry(Limiter, default),
            {error, {rate_limited, Info}}
    end.

%%----------------------------------------------------------------------
%% Internal - Telemetry
%%----------------------------------------------------------------------

emit_check_telemetry(Name, Key, Cost, Result) ->
    {Status, Measurements} =
        case Result of
            {allow, #{remaining := Remaining}} ->
                {allow, #{remaining => Remaining, cost => Cost}};
            {deny, #{retry_after := RetryAfter}} ->
                {deny, #{retry_after => RetryAfter, cost => Cost}}
        end,
    telemetry:execute(
        [seki, rate_limit, Status],
        Measurements,
        #{name => Name, key => Key}
    ).

emit_denied_telemetry(Name, Key) ->
    telemetry:execute(
        [seki, rate_limit, denied],
        #{count => 1},
        #{name => Name, key => Key}
    ).
