-module(seki_health).

%% Deep health checking with dependency aggregation and BEAM VM awareness.
%%
%% Provides three health states:
%%   - healthy: all checks pass
%%   - degraded: some non-critical checks fail
%%   - unhealthy: critical checks fail
%%
%% Built-in checks:
%%   - BEAM VM: scheduler utilization, run queue, memory, process count
%%   - Custom: register arbitrary check functions
%%
%% Compatible with Kubernetes liveness/readiness/startup probes.

-behaviour(gen_server).

-export([
    start_link/1,
    start_link/2,
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

-record(check, {
    name :: atom(),
    fun_ :: check_fun(),
    critical :: boolean(),
    last_result :: check_result() | undefined,
    last_check :: integer() | undefined
}).

-record(state, {
    name :: atom(),
    checks :: #{atom() => #check{}},
    check_interval :: pos_integer(),
    vm_checks :: boolean()
}).

%%----------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------

start_link(Name) ->
    start_link(Name, #{}).

start_link(Name, Opts) ->
    gen_server:start_link({local, Name}, ?MODULE, {Name, Opts}, []).

-spec register_check(atom(), atom(), check_fun()) -> ok.
register_check(Name, CheckName, Fun) ->
    register_check(Name, CheckName, Fun, #{}).

-spec register_check(atom(), atom(), check_fun(), map()) -> ok.
register_check(Name, CheckName, Fun, Opts) ->
    Critical = maps:get(critical, Opts, false),
    gen_server:call(Name, {register, CheckName, Fun, Critical}).

-spec unregister_check(atom(), atom()) -> ok.
unregister_check(Name, CheckName) ->
    gen_server:call(Name, {unregister, CheckName}).

-spec check(atom()) -> #{health := health(), checks := map()}.
check(Name) ->
    gen_server:call(Name, check).

-spec check_one(atom(), atom()) -> check_result() | {error, not_found}.
check_one(Name, CheckName) ->
    gen_server:call(Name, {check_one, CheckName}).

%% Kubernetes liveness: is the process alive and responsive?
-spec liveness(atom()) -> ok | {error, unhealthy}.
liveness(Name) ->
    try
        gen_server:call(Name, liveness, 5000)
    catch
        _:_ -> {error, unhealthy}
    end.

%% Kubernetes readiness: is the service ready to accept traffic?
-spec readiness(atom()) -> ok | {error, term()}.
readiness(Name) ->
    case check(Name) of
        #{health := unhealthy} -> {error, unhealthy};
        _ -> ok
    end.

-spec status(atom()) -> map().
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
handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(run_checks, State) ->
    {_, NewState} = run_all_checks(State),
    schedule_check(State#state.check_interval),
    {noreply, NewState};
handle_info(_Info, State) ->
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
            {maps:put(Name, Result, Acc), maps:put(Name, NewCheck, CheckAcc)}
        end,
        {#{}, #{}},
        State#state.checks
    ),
    OverallHealth = aggregate_health(Results, State#state.checks),
    emit_health(State#state.name, OverallHealth, Results),
    {#{health => OverallHealth, checks => Results}, State#state{checks = NewChecks}}.

run_check(#check{fun_ = Fun} = Check) ->
    Now = erlang:monotonic_time(millisecond),
    Result =
        try
            Fun()
        catch
            _:Reason ->
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
    MemInfo = erlang:memory(),
    TotalMB = proplists:get_value(total, MemInfo) div (1024 * 1024),
    ProcessMB = proplists:get_value(processes, MemInfo) div (1024 * 1024),
    SystemLimit = erlang:system_info(system_memory_allocation_info),
    %% Use process limit as heuristic — high memory is degraded, not unhealthy
    Health =
        case TotalMB > 4096 of
            true -> degraded;
            false -> healthy
        end,
    {Health, #{
        total_mb => TotalMB,
        process_mb => ProcessMB,
        system_info => SystemLimit
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
    PerScheduler = RunQueue / max(1, Schedulers),
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
