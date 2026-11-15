-module(seki_health).

-moduledoc """
Deep health checking with dependency aggregation and BEAM VM awareness.

Three health states: `healthy`, `degraded`, `unhealthy`. Built-in BEAM VM
checks (memory, processes, run queue) run automatically. Register custom
checks for dependencies (databases, external services).

Compatible with Kubernetes liveness/readiness/startup probes via
`liveness/1` and `readiness/1`.

## Example

    seki_health:start_link(my_app_health, #{vm_checks => true}).
    seki_health:register_check(my_app_health, database, fun() ->
        case db:ping() of
            ok -> {healthy, #{}};
            _ -> {unhealthy, #{reason => db_down}}
        end
    end, #{critical => true}).
    ok = seki_health:readiness(my_app_health).
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/1,
    start_link/2,
    check_options/1,
    register_check/3,
    register_check/4,
    unregister_check/2,
    check/1,
    check_one/2,
    liveness/1,
    readiness/1,
    status/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-type health() :: healthy | degraded | unhealthy.
-type check_result() :: {health(), map()}.
-type check_fun() :: fun(() -> check_result()).

-export_type([health/0, check_result/0, check_fun/0]).

-define(IS_HEALTH(Health),
    (Health =:= healthy orelse Health =:= degraded orelse Health =:= unhealthy)
).

-record(check, {
    name :: atom(),
    fun_ :: fun(() -> term()),
    critical :: boolean(),
    last_result :: check_result() | undefined,
    last_check :: integer() | undefined
}).

-record(state, {
    name :: seki:name(),
    checks :: #{atom() => #check{}},
    check_interval :: pos_integer(),
    vm_checks :: boolean()
}).

%%----------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------

-doc false.
start_link(Name) ->
    start_link(Name, #{}).

-doc false.
start_link(Name, Opts) ->
    case check_options(Opts) of
        ok -> gen_server:start_link(seki_registry:registration(Name), ?MODULE, {Name, Opts}, []);
        {error, Reason} -> {error, Reason}
    end.

-doc false.
-spec check_options(term()) -> ok | {error, seki_options:invalid()}.
check_options(Opts) ->
    seki_options:check(Opts, [{vm_checks, boolean}, {check_interval, pos_integer}]).

-doc "Register a health check function. Optionally mark as critical.".
-spec register_check(seki:name(), atom(), check_fun()) -> ok.
register_check(Name, CheckName, Fun) ->
    register_check(Name, CheckName, Fun, #{}).

-doc """
Register a health check with options. Set `#{critical => true}` to make failures return unhealthy.

The function returns `{Health, Details}`, with `Details` a map. A check that
returns anything else is reported as
`{unhealthy, #{error => {invalid_result, Returned}}}`.
""".
-spec register_check(seki:name(), atom(), check_fun(), map()) -> ok.
register_check(Name, CheckName, Fun, Opts) ->
    Critical = maps:get(critical, Opts, false),
    ok = gen_server:call(seki_registry:server(Name), {register, CheckName, Fun, Critical}).

-doc "Remove a previously registered health check.".
-spec unregister_check(seki:name(), atom()) -> ok.
unregister_check(Name, CheckName) ->
    ok = gen_server:call(seki_registry:server(Name), {unregister, CheckName}).

-doc "Run all health checks and return aggregated health status.".
-spec check(seki:name()) -> #{health := health(), checks := map()}.
check(Name) ->
    check_reply(gen_server:call(seki_registry:server(Name), check)).

-spec check_reply(term()) -> #{health := health(), checks := map()}.
check_reply(#{health := Health, checks := Checks}) when ?IS_HEALTH(Health), is_map(Checks) ->
    #{health => Health, checks => Checks}.

-doc "Run a single named health check.".
-spec check_one(seki:name(), atom()) -> check_result() | {error, not_found}.
check_one(Name, CheckName) ->
    case gen_server:call(seki_registry:server(Name), {check_one, CheckName}) of
        {error, not_found} -> {error, not_found};
        {Health, Details} when ?IS_HEALTH(Health), is_map(Details) -> {Health, Details}
    end.

-doc "Kubernetes liveness probe — checks if the process is alive and responsive.".
-spec liveness(seki:name()) -> ok | {error, unhealthy}.
liveness(Name) ->
    try
        ok = gen_server:call(seki_registry:server(Name), liveness, 5000)
    catch
        _:_ -> {error, unhealthy}
    end.

-doc "Kubernetes readiness probe — returns `ok` unless health is `unhealthy`.".
-spec readiness(seki:name()) -> ok | {error, term()}.
readiness(Name) ->
    case check(Name) of
        #{health := unhealthy} -> {error, unhealthy};
        _ -> ok
    end.

-doc "Alias for `check/1`.".
-spec status(seki:name()) -> map().
status(Name) ->
    check(Name).

%%----------------------------------------------------------------------
%% gen_server callbacks
%%----------------------------------------------------------------------

init({Name, Opts}) ->
    VMChecks = maps:get(vm_checks, Opts, true),
    Interval = maps:get(check_interval, Opts, 10000),
    State0 = #state{
        name = Name,
        checks = #{},
        check_interval = Interval,
        vm_checks = VMChecks
    },
    State = maybe_add_vm_checks(State0),
    schedule_check(Interval),
    {ok, State}.

handle_call({register, CheckName, Fun, Critical}, _From, State) ->
    Check = #check{
        name = CheckName,
        fun_ = Fun,
        critical = Critical,
        last_result = undefined,
        last_check = undefined
    },
    NewChecks = maps:put(CheckName, Check, State#state.checks),
    {reply, ok, State#state{checks = NewChecks}};
handle_call({unregister, CheckName}, _From, State) ->
    NewChecks = maps:remove(CheckName, State#state.checks),
    {reply, ok, State#state{checks = NewChecks}};
handle_call(check, _From, State) ->
    {Result, NewState} = run_all_checks(State),
    {reply, Result, NewState};
handle_call({check_one, CheckName}, _From, State) ->
    case maps:get(CheckName, State#state.checks, undefined) of
        undefined ->
            {reply, {error, not_found}, State};
        Check ->
            {CheckResult, NewCheck} = run_check(Check),
            NewChecks = maps:put(CheckName, NewCheck, State#state.checks),
            {reply, CheckResult, State#state{checks = NewChecks}}
    end;
handle_call(liveness, _From, State) ->
    {reply, ok, State};
handle_call(Request, _From, State) ->
    ok = seki_unexpected:dropped(?MODULE, call, Request),
    {reply, {error, unknown}, State}.

handle_cast(Message, State) ->
    ok = seki_unexpected:dropped(?MODULE, cast, Message),
    {noreply, State}.

handle_info(run_checks, State) ->
    {_, NewState} = run_all_checks(State),
    schedule_check(State#state.check_interval),
    {noreply, NewState};
handle_info(Message, State) ->
    ok = seki_unexpected:dropped(?MODULE, info, Message),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

run_all_checks(State) ->
    {Results, NewChecks} = maps:fold(
        fun(Name, Check, {Acc, CheckAcc}) ->
            {Result, NewCheck} = run_check(Check),
            {Acc#{Name => Result}, CheckAcc#{Name => NewCheck}}
        end,
        {#{}, #{}},
        State#state.checks
    ),
    OverallHealth = aggregate_health(Results, State#state.checks),
    case OverallHealth of
        unhealthy ->
            FailedChecks = maps:fold(
                fun
                    (N, {H, _}, Acc) when H =:= unhealthy -> [N | Acc];
                    (_, _, Acc) -> Acc
                end,
                [],
                Results
            ),
            ?LOG_ERROR(
                #{
                    msg => health_unhealthy,
                    name => seki_name:label(State#state.name),
                    failed_checks => FailedChecks
                },
                #{domain => [seki]}
            );
        degraded ->
            ?LOG_WARNING(
                #{msg => health_degraded, name => seki_name:label(State#state.name)},
                #{domain => [seki]}
            );
        healthy ->
            ok
    end,
    emit_health(State#state.name, OverallHealth, Results),
    {#{health => OverallHealth, checks => Results}, State#state{checks = NewChecks}}.

run_check(#check{fun_ = Fun} = Check) ->
    Now = erlang:monotonic_time(millisecond),
    Result =
        try Fun() of
            {Health, Details} when ?IS_HEALTH(Health), is_map(Details) ->
                {Health, Details};
            Invalid ->
                ?LOG_ERROR(
                    #{msg => health_check_returned_no_health, check => Check#check.name},
                    #{domain => [seki]}
                ),
                {unhealthy, #{error => {invalid_result, Invalid}}}
        catch
            _:Reason ->
                logger:error(
                    "Health check ~p threw exception: ~p",
                    [Check#check.name, Reason],
                    #{domain => [seki]}
                ),
                {unhealthy, #{error => Reason}}
        end,
    {Result, Check#check{last_result = Result, last_check = Now}}.

aggregate_health(Results, CheckDefs) ->
    maps:fold(
        fun(Name, {Health, _}, Acc) ->
            Critical = is_critical(Name, CheckDefs),
            case {Health, Critical, Acc} of
                {unhealthy, true, _} -> unhealthy;
                {unhealthy, false, healthy} -> degraded;
                {unhealthy, false, _} -> Acc;
                {degraded, _, healthy} -> degraded;
                {degraded, _, _} -> Acc;
                {healthy, _, _} -> Acc
            end
        end,
        healthy,
        Results
    ).

is_critical(Name, CheckDefs) ->
    case maps:get(Name, CheckDefs, undefined) of
        #check{critical = Critical} -> Critical;
        _ -> false
    end.

schedule_check(Interval) ->
    erlang:send_after(Interval, self(), run_checks).

%%----------------------------------------------------------------------
%% Built-in VM checks
%%----------------------------------------------------------------------

maybe_add_vm_checks(#state{vm_checks = false} = State) ->
    State;
maybe_add_vm_checks(State) ->
    Checks = #{
        vm_memory => #check{
            name = vm_memory,
            fun_ = fun check_vm_memory/0,
            critical = false,
            last_result = undefined,
            last_check = undefined
        },
        vm_processes => #check{
            name = vm_processes,
            fun_ = fun check_vm_processes/0,
            critical = false,
            last_result = undefined,
            last_check = undefined
        },
        vm_run_queue => #check{
            name = vm_run_queue,
            fun_ = fun check_vm_run_queue/0,
            critical = false,
            last_result = undefined,
            last_check = undefined
        }
    },
    State#state{checks = maps:merge(Checks, State#state.checks)}.

check_vm_memory() ->
    TotalMB = erlang:memory(total) div (1024 * 1024),
    ProcessMB = erlang:memory(processes) div (1024 * 1024),
    %% Use process limit as heuristic — high memory is degraded, not unhealthy
    Health =
        case TotalMB > 4096 of
            true -> degraded;
            false -> healthy
        end,
    {Health, #{
        total_mb => TotalMB,
        process_mb => ProcessMB
    }}.

check_vm_processes() ->
    Count = erlang:system_info(process_count),
    Limit = erlang:system_info(process_limit),
    Utilization = Count / Limit,
    Health =
        case Utilization of
            U when U > 0.9 -> unhealthy;
            U when U > 0.7 -> degraded;
            _ -> healthy
        end,
    {Health, #{
        count => Count,
        limit => Limit,
        utilization => Utilization
    }}.

check_vm_run_queue() ->
    RunQueue = erlang:statistics(total_run_queue_lengths_all),
    Schedulers = erlang:system_info(schedulers_online),
    PerScheduler = RunQueue / seki_number:larger(1, Schedulers),
    Health =
        case PerScheduler of
            P when P > 10.0 -> unhealthy;
            P when P > 5.0 -> degraded;
            _ -> healthy
        end,
    {Health, #{
        total_run_queue => RunQueue,
        schedulers => Schedulers,
        per_scheduler => PerScheduler
    }}.

%%----------------------------------------------------------------------
%% Telemetry
%%----------------------------------------------------------------------

emit_health(Name, Health, Checks) ->
    telemetry:execute(
        [seki, health, check],
        #{check_count => maps:size(Checks)},
        #{name => Name, health => Health, checks => Checks}
    ).
