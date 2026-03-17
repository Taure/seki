-module(seki_adaptive).

-moduledoc """
Adaptive concurrency limiter inspired by Netflix's concurrency-limits library.

Dynamically adjusts the maximum concurrency based on observed latency.

Two algorithms:

- **AIMD** — Additive Increase, Multiplicative Decrease. Simple, stable. Good default.
- **Gradient** — Tracks long/short-term latency via exponential moving averages.
  Increases limit when latency improves, decreases when it worsens.

## Example

    seki_adaptive:start_link(my_service, #{algorithm => aimd, initial_limit => 20}).
    {ok, Result} = seki_adaptive:call(my_service, fun() -> do_work() end).
""".

-behaviour(gen_server).

-export([
    start_link/2,
    acquire/1,
    release/2,
    call/2,
    call/3,
    status/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-type algorithm() :: aimd | gradient.
-type outcome() :: ok | error | timeout | drop.

-type opts() :: #{
    algorithm => algorithm(),
    min_limit => pos_integer(),
    max_limit => pos_integer(),
    initial_limit => pos_integer(),
    %% AIMD options
    backoff_ratio => float(),
    %% Gradient options
    smoothing => float(),
    tolerance => float(),
    long_window => pos_integer()
}.

-export_type([algorithm/0, outcome/0, opts/0]).

-record(state, {
    name :: atom(),
    algorithm :: algorithm(),
    min_limit :: pos_integer(),
    max_limit :: pos_integer(),
    current_limit :: float(),
    in_flight :: non_neg_integer(),
    %% AIMD
    backoff_ratio :: float(),
    %% Gradient
    long_rtt :: float(),
    short_rtt :: float(),
    smoothing :: float(),
    tolerance :: float(),
    long_smoothing :: float(),
    %% Tracking
    monitors :: #{reference() => {pid(), integer()}}
}).

%%----------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------

-doc false.
start_link(Name, Opts) ->
    gen_server:start_link({local, Name}, ?MODULE, {Name, Opts}, []).

-doc "Acquire a concurrency slot. Returns `{error, limit_reached}` if at capacity.".
-spec acquire(atom()) -> ok | {error, limit_reached}.
acquire(Name) ->
    gen_server:call(Name, {acquire, self()}).

-doc "Release a slot and report the outcome. The outcome adjusts the concurrency limit.".
-spec release(atom(), outcome()) -> ok.
release(Name, Outcome) ->
    gen_server:cast(Name, {release, self(), Outcome}).

-doc "Execute a function with automatic acquire/release and outcome reporting.".
-spec call(atom(), fun(() -> term())) -> {ok, term()} | {error, limit_reached}.
call(Name, Fun) ->
    call(Name, Fun, #{}).

-doc "Execute a function with automatic acquire/release, outcome reporting, and options.".
-spec call(atom(), fun(() -> term()), map()) -> {ok, term()} | {error, limit_reached}.
call(Name, Fun, _Opts) ->
    case acquire(Name) of
        ok ->
            try
                Result = Fun(),
                release(Name, ok),
                {ok, Result}
            catch
                Class:Reason:Stacktrace ->
                    release(Name, error),
                    {error, {Class, Reason, Stacktrace}}
            end;
        {error, limit_reached} = Error ->
            Error
    end.

-doc "Get current adaptive limiter status (current_limit, in_flight, available).".
-spec status(atom()) ->
    #{
        current_limit := pos_integer(),
        in_flight := non_neg_integer(),
        available := non_neg_integer()
    }.
status(Name) ->
    gen_server:call(Name, status).

%%----------------------------------------------------------------------
%% gen_server callbacks
%%----------------------------------------------------------------------

init({Name, Opts}) ->
    Algorithm = maps:get(algorithm, Opts, aimd),
    InitialLimit = maps:get(initial_limit, Opts, 20),
    Smoothing = maps:get(smoothing, Opts, 0.2),
    State = #state{
        name = Name,
        algorithm = Algorithm,
        min_limit = maps:get(min_limit, Opts, 1),
        max_limit = maps:get(max_limit, Opts, 1000),
        current_limit = InitialLimit * 1.0,
        in_flight = 0,
        backoff_ratio = maps:get(backoff_ratio, Opts, 0.9),
        long_rtt = 0.0,
        short_rtt = 0.0,
        smoothing = Smoothing,
        tolerance = maps:get(tolerance, Opts, 1.5),
        long_smoothing = maps:get(long_smoothing, Opts, Smoothing / 10),
        monitors = #{}
    },
    {ok, State}.

handle_call({acquire, Pid}, _From, State) ->
    #state{in_flight = InFlight, current_limit = Limit} = State,
    case InFlight < trunc(Limit) of
        true ->
            MonRef = monitor(process, Pid),
            Now = erlang:monotonic_time(millisecond),
            NewMonitors = maps:put(MonRef, {Pid, Now}, State#state.monitors),
            NewState = State#state{
                in_flight = InFlight + 1,
                monitors = NewMonitors
            },
            emit_acquire(State#state.name, InFlight + 1, trunc(Limit)),
            {reply, ok, NewState};
        false ->
            logger:warning(
                "Adaptive limiter ~p at capacity (limit=~p, in_flight=~p)",
                [State#state.name, trunc(Limit), InFlight],
                #{domain => [seki]}
            ),
            emit_rejected(State#state.name, trunc(Limit)),
            {reply, {error, limit_reached}, State}
    end;
handle_call(status, _From, State) ->
    #state{current_limit = Limit, in_flight = InFlight} = State,
    IntLimit = trunc(Limit),
    {reply,
        #{
            current_limit => IntLimit,
            in_flight => InFlight,
            available => max(0, IntLimit - InFlight)
        },
        State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({release, Pid, Outcome}, State) ->
    case find_monitor_by_pid(Pid, State#state.monitors) of
        {ok, MonRef, StartTime} ->
            demonitor(MonRef, [flush]),
            Duration = erlang:monotonic_time(millisecond) - StartTime,
            NewMonitors = maps:remove(MonRef, State#state.monitors),
            NewState0 = State#state{
                in_flight = max(0, State#state.in_flight - 1),
                monitors = NewMonitors
            },
            NewState = adjust_limit(Outcome, Duration, NewState0),
            emit_release(
                NewState#state.name, NewState#state.in_flight, trunc(NewState#state.current_limit)
            ),
            {noreply, NewState};
        error ->
            {noreply, State}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', MonRef, process, Pid, Reason}, State) ->
    case maps:take(MonRef, State#state.monitors) of
        {{_, StartTime}, NewMonitors} ->
            logger:warning(
                "Adaptive limiter ~p: process ~p died (~p), releasing slot",
                [State#state.name, Pid, Reason],
                #{domain => [seki]}
            ),
            Duration = erlang:monotonic_time(millisecond) - StartTime,
            NewState0 = State#state{
                in_flight = max(0, State#state.in_flight - 1),
                monitors = NewMonitors
            },
            NewState = adjust_limit(error, Duration, NewState0),
            {noreply, NewState};
        error ->
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%----------------------------------------------------------------------
%% Limit adjustment algorithms
%%----------------------------------------------------------------------

adjust_limit(Outcome, Duration, #state{algorithm = aimd} = State) ->
    adjust_aimd(Outcome, Duration, State);
adjust_limit(Outcome, Duration, #state{algorithm = gradient} = State) ->
    adjust_gradient(Outcome, Duration, State).

%% AIMD: Additive Increase, Multiplicative Decrease
adjust_aimd(ok, _Duration, State) ->
    #state{current_limit = Limit, max_limit = MaxLimit, min_limit = MinLimit} = State,
    %% Additive increase: add 1/current_limit (so it takes ~limit successes to increase by 1)
    NewLimit = min(MaxLimit * 1.0, Limit + 1.0 / max(1.0, Limit)),
    emit_limit_change(State#state.name, trunc(Limit), trunc(NewLimit)),
    State#state{current_limit = max(MinLimit * 1.0, NewLimit)};
adjust_aimd(_, _Duration, State) ->
    #state{current_limit = Limit, backoff_ratio = Ratio, min_limit = MinLimit} = State,
    %% Multiplicative decrease
    NewLimit = max(MinLimit * 1.0, Limit * Ratio),
    emit_limit_change(State#state.name, trunc(Limit), trunc(NewLimit)),
    State#state{current_limit = NewLimit}.

%% Gradient: Track latency trend
adjust_gradient(drop, _Duration, State) ->
    #state{current_limit = Limit, min_limit = MinLimit} = State,
    NewLimit = max(MinLimit * 1.0, Limit * 0.9),
    emit_limit_change(State#state.name, trunc(Limit), trunc(NewLimit)),
    State#state{current_limit = NewLimit};
adjust_gradient(error, _Duration, State) ->
    %% Errors don't change limit in gradient mode (only latency matters)
    State;
adjust_gradient(ok, Duration, State) ->
    #state{
        current_limit = Limit,
        long_rtt = LongRTT,
        short_rtt = ShortRTT,
        smoothing = Alpha,
        long_smoothing = LongAlpha,
        tolerance = Tolerance,
        min_limit = MinLimit,
        max_limit = MaxLimit
    } = State,
    DurationF = Duration * 1.0,
    %% Update exponential moving averages
    NewShortRTT = ema(ShortRTT, DurationF, Alpha),
    NewLongRTT = ema(LongRTT, DurationF, LongAlpha),
    %% Calculate gradient: ratio of long-term to short-term latency
    Gradient =
        case NewShortRTT > 0.001 of
            true -> max(0.5, min(2.0, NewLongRTT / NewShortRTT));
            false -> 1.0
        end,
    %% Adjust limit based on gradient
    NewLimit =
        case Gradient >= Tolerance of
            true ->
                %% Latency increasing — reduce limit
                max(MinLimit * 1.0, Limit * Gradient * 0.9);
            false ->
                %% Latency stable or improving — increase limit
                min(MaxLimit * 1.0, Limit + 1.0 / max(1.0, Limit))
        end,
    emit_limit_change(State#state.name, trunc(Limit), trunc(NewLimit)),
    State#state{
        current_limit = NewLimit,
        long_rtt = NewLongRTT,
        short_rtt = NewShortRTT
    };
adjust_gradient(timeout, Duration, State) ->
    adjust_gradient(drop, Duration, State).

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

find_monitor_by_pid(Pid, Monitors) ->
    Result = maps:fold(
        fun
            (MonRef, {P, StartTime}, error) when P =:= Pid ->
                {ok, MonRef, StartTime};
            (_, _, Acc) ->
                Acc
        end,
        error,
        Monitors
    ),
    Result.

ema(Current, New, _Alpha) when Current < 0.001 ->
    New;
ema(Current, New, Alpha) ->
    Current * (1 - Alpha) + New * Alpha.

%%----------------------------------------------------------------------
%% Telemetry
%%----------------------------------------------------------------------

emit_acquire(Name, InFlight, Limit) ->
    telemetry:execute(
        [seki, adaptive, acquire],
        #{in_flight => InFlight, limit => Limit},
        #{name => Name}
    ).

emit_release(Name, InFlight, Limit) ->
    telemetry:execute(
        [seki, adaptive, release],
        #{in_flight => InFlight, limit => Limit},
        #{name => Name}
    ).

emit_rejected(Name, Limit) ->
    telemetry:execute(
        [seki, adaptive, rejected],
        #{limit => Limit},
        #{name => Name}
    ).

emit_limit_change(Name, OldLimit, NewLimit) ->
    telemetry:execute(
        [seki, adaptive, limit_change],
        #{old_limit => OldLimit, new_limit => NewLimit},
        #{name => Name}
    ).
