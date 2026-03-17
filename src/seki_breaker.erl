-module(seki_breaker).

-moduledoc """
Circuit breaker as a `gen_statem` with three states: closed, open, half_open.

Tracks failure and slow-call rates in a sliding window. When thresholds are
exceeded, the breaker opens and rejects calls with `{error, circuit_open}`.
After a wait period, it transitions to half-open and allows probe requests.

Typically used via `seki:call/2` rather than directly.
""".

-behaviour(gen_statem).

%% API
-export([
    start_link/2,
    call/3,
    get_state/1,
    reset/1
]).

%% gen_statem callbacks
-export([
    init/1,
    callback_mode/0,
    closed/3,
    open/3,
    half_open/3,
    terminate/3
]).

-record(data, {
    name :: atom(),
    %% Sliding window for failure tracking
    window_type :: count | time,
    window_size :: pos_integer(),
    failure_threshold :: 1..100,
    slow_call_threshold :: 1..100,
    slow_call_duration :: pos_integer(),
    wait_duration :: pos_integer(),
    half_open_requests :: pos_integer(),
    error_classifier :: fun((term()) -> boolean()),
    %% State tracking
    outcomes :: queue:queue({ok | error | slow, integer()}),
    outcome_count :: non_neg_integer(),
    half_open_count :: non_neg_integer()
}).

%%----------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------

-doc false.
start_link(Name, Opts) ->
    gen_statem:start_link({local, Name}, ?MODULE, {Name, Opts}, []).

-doc "Execute a function through this breaker. Returns `{error, circuit_open}` when open.".
-spec call(atom(), fun(() -> term()), map()) -> seki:call_result().
call(Name, Fun, _CallOpts) ->
    gen_statem:call(Name, {call, Fun}).

-doc "Get the current breaker state.".
-spec get_state(atom()) -> closed | open | half_open.
get_state(Name) ->
    gen_statem:call(Name, get_state).

-doc "Reset the breaker to closed state.".
-spec reset(atom()) -> ok.
reset(Name) ->
    gen_statem:cast(Name, reset).

%%----------------------------------------------------------------------
%% gen_statem callbacks
%%----------------------------------------------------------------------

callback_mode() ->
    state_functions.

init({Name, Opts}) ->
    DefaultClassifier = fun
        ({error, _}) -> true;
        (error) -> true;
        (_) -> false
    end,
    Data = #data{
        name = Name,
        window_type = maps:get(window_type, Opts, count),
        window_size = maps:get(window_size, Opts, 20),
        failure_threshold = maps:get(failure_threshold, Opts, 50),
        slow_call_threshold = maps:get(slow_call_threshold, Opts, 80),
        slow_call_duration = maps:get(slow_call_duration, Opts, 2000),
        wait_duration = maps:get(wait_duration, Opts, 30000),
        half_open_requests = maps:get(half_open_requests, Opts, 5),
        error_classifier = maps:get(error_classifier, Opts, DefaultClassifier),
        outcomes = queue:new(),
        outcome_count = 0,
        half_open_count = 0
    },
    emit_state_change(Name, undefined, closed),
    {ok, closed, Data}.

%%----------------------------------------------------------------------
%% CLOSED state
%%----------------------------------------------------------------------

closed({call, From}, {call, Fun}, Data) ->
    #data{name = Name, slow_call_duration = SlowDuration, error_classifier = Classifier} = Data,
    Start = erlang:monotonic_time(millisecond),
    try Fun() of
        Result ->
            Duration = erlang:monotonic_time(millisecond) - Start,
            Outcome =
                case Classifier(Result) of
                    true -> error;
                    false when Duration >= SlowDuration -> slow;
                    false -> ok
                end,
            emit_call_telemetry(Name, closed, Outcome, Duration),
            NewData = record_outcome(Outcome, Data),
            case should_trip(NewData) of
                true ->
                    emit_state_change(Name, closed, open),
                    {next_state, open, reset_outcomes(NewData), [
                        {reply, From, wrap_result(Result)},
                        {state_timeout, NewData#data.wait_duration, try_half_open}
                    ]};
                false ->
                    {keep_state, NewData, [{reply, From, wrap_result(Result)}]}
            end
    catch
        Class:Reason:Stacktrace ->
            Duration = erlang:monotonic_time(millisecond) - Start,
            emit_call_telemetry(Name, closed, error, Duration),
            NewData = record_outcome(error, Data),
            case should_trip(NewData) of
                true ->
                    emit_state_change(Name, closed, open),
                    {next_state, open, reset_outcomes(NewData), [
                        {reply, From, {error, {Class, Reason, Stacktrace}}},
                        {state_timeout, NewData#data.wait_duration, try_half_open}
                    ]};
                false ->
                    {keep_state, NewData, [{reply, From, {error, {Class, Reason, Stacktrace}}}]}
            end
    end;
closed({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, closed}]};
closed(cast, reset, Data) ->
    {keep_state, reset_outcomes(Data)}.

%%----------------------------------------------------------------------
%% OPEN state
%%----------------------------------------------------------------------

open({call, From}, {call, _Fun}, #data{name = Name}) ->
    emit_call_telemetry(Name, open, rejected, 0),
    {keep_state_and_data, [{reply, From, {error, circuit_open}}]};
open({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, open}]};
open(cast, reset, Data) ->
    emit_state_change(Data#data.name, open, closed),
    {next_state, closed, reset_outcomes(Data)};
open(state_timeout, try_half_open, Data) ->
    emit_state_change(Data#data.name, open, half_open),
    {next_state, half_open, Data#data{half_open_count = 0}}.

%%----------------------------------------------------------------------
%% HALF_OPEN state
%%----------------------------------------------------------------------

half_open({call, From}, {call, Fun}, Data) ->
    #data{
        name = Name,
        half_open_requests = MaxRequests,
        half_open_count = Count,
        slow_call_duration = SlowDuration,
        error_classifier = Classifier,
        wait_duration = WaitDuration
    } = Data,
    case Count >= MaxRequests of
        true ->
            %% Already have enough probes in flight, reject
            emit_call_telemetry(Name, half_open, rejected, 0),
            {keep_state_and_data, [{reply, From, {error, circuit_open}}]};
        false ->
            NewData = Data#data{half_open_count = Count + 1},
            Start = erlang:monotonic_time(millisecond),
            try Fun() of
                Result ->
                    Duration = erlang:monotonic_time(millisecond) - Start,
                    Outcome =
                        case Classifier(Result) of
                            true -> error;
                            false when Duration >= SlowDuration -> slow;
                            false -> ok
                        end,
                    emit_call_telemetry(Name, half_open, Outcome, Duration),
                    NewData2 = record_outcome(Outcome, NewData),
                    case Outcome of
                        ok ->
                            case NewData2#data.half_open_count >= MaxRequests of
                                true ->
                                    %% All probes succeeded, close
                                    emit_state_change(Name, half_open, closed),
                                    {next_state, closed, reset_outcomes(NewData2), [
                                        {reply, From, wrap_result(Result)}
                                    ]};
                                false ->
                                    {keep_state, NewData2, [{reply, From, wrap_result(Result)}]}
                            end;
                        _ ->
                            %% Probe failed, back to open
                            emit_state_change(Name, half_open, open),
                            {next_state, open, reset_outcomes(NewData2), [
                                {reply, From, wrap_result(Result)},
                                {state_timeout, WaitDuration, try_half_open}
                            ]}
                    end
            catch
                Class:Reason:Stacktrace ->
                    Duration = erlang:monotonic_time(millisecond) - Start,
                    emit_call_telemetry(Name, half_open, error, Duration),
                    emit_state_change(Name, half_open, open),
                    {next_state, open, reset_outcomes(NewData), [
                        {reply, From, {error, {Class, Reason, Stacktrace}}},
                        {state_timeout, WaitDuration, try_half_open}
                    ]}
            end
    end;
half_open({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, half_open}]};
half_open(cast, reset, Data) ->
    emit_state_change(Data#data.name, half_open, closed),
    {next_state, closed, reset_outcomes(Data)}.

terminate(_Reason, _State, _Data) ->
    ok.

%%----------------------------------------------------------------------
%% Internal - Outcome tracking
%%----------------------------------------------------------------------

record_outcome(Outcome, #data{window_type = count, window_size = Size} = Data) ->
    #data{outcomes = Q, outcome_count = Count} = Data,
    Now = erlang:monotonic_time(millisecond),
    Q2 = queue:in({Outcome, Now}, Q),
    case Count >= Size of
        true ->
            {_, Q3} = queue:out(Q2),
            Data#data{outcomes = Q3};
        false ->
            Data#data{outcomes = Q2, outcome_count = Count + 1}
    end;
record_outcome(Outcome, #data{window_type = time, window_size = WindowMs} = Data) ->
    #data{outcomes = Q, outcome_count = Count} = Data,
    Now = erlang:monotonic_time(millisecond),
    Cutoff = Now - WindowMs,
    Q2 = queue:in({Outcome, Now}, Q),
    {Q3, Removed} = prune_old(Q2, Cutoff, 0),
    Data#data{outcomes = Q3, outcome_count = Count + 1 - Removed}.

should_trip(#data{outcome_count = Count}) when Count < 5 ->
    %% Minimum sample size
    false;
should_trip(Data) ->
    #data{
        failure_threshold = FailThreshold,
        slow_call_threshold = SlowThreshold,
        outcomes = Q
    } = Data,
    Outcomes = queue:to_list(Q),
    Total = length(Outcomes),
    case Total of
        0 ->
            false;
        _ ->
            Errors = length([O || {O, _} <- Outcomes, O =:= error]),
            Slows = length([O || {O, _} <- Outcomes, O =:= slow]),
            FailRate = (Errors * 100) div Total,
            SlowRate = ((Errors + Slows) * 100) div Total,
            FailRate >= FailThreshold orelse SlowRate >= SlowThreshold
    end.

reset_outcomes(Data) ->
    Data#data{outcomes = queue:new(), outcome_count = 0, half_open_count = 0}.

prune_old(Q, Cutoff, Removed) ->
    case queue:peek(Q) of
        {value, {_, Ts}} when Ts < Cutoff ->
            {_, Q2} = queue:out(Q),
            prune_old(Q2, Cutoff, Removed + 1);
        _ ->
            {Q, Removed}
    end.

wrap_result(Result) ->
    {ok, Result}.

%%----------------------------------------------------------------------
%% Internal - Telemetry
%%----------------------------------------------------------------------

emit_state_change(Name, From, To) ->
    telemetry:execute(
        [seki, breaker, state_change],
        #{system_time => erlang:system_time(millisecond)},
        #{name => Name, from => From, to => To}
    ).

emit_call_telemetry(Name, State, Outcome, Duration) ->
    telemetry:execute(
        [seki, breaker, call],
        #{duration => Duration},
        #{name => Name, state => State, outcome => Outcome}
    ).
