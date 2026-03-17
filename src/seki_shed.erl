-module(seki_shed).

%% Load shedding with CoDel (Controlled Delay) and priority-based admission.
%%
%% CoDel tracks how long requests spend queued (sojourn time). If sojourn
%% time consistently exceeds a target (e.g., 5ms), CoDel begins dropping
%% requests at an increasing rate. When sojourn time returns to target,
%% dropping stops immediately.
%%
%% Priority-based shedding assigns each request a priority level (0-3).
%% Under load, lower-priority requests are shed first:
%%   P0 (critical)  — never shed
%%   P1 (important) — shed at 90% capacity
%%   P2 (normal)    — shed at 80% capacity
%%   P3 (low)       — shed at 70% capacity
%%
%% Usage:
%%   seki_shed:start_link(my_shed, #{...}).
%%   case seki_shed:admit(my_shed, Priority) of
%%       ok -> handle_request();
%%       {error, shed} -> reply_503()
%%   end.
%%   seki_shed:complete(my_shed, Duration).

-behaviour(gen_server).

-export([
    start_link/2,
    admit/2,
    admit/1,
    complete/2,
    status/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-type priority() :: 0 | 1 | 2 | 3.

-type opts() :: #{
    %% CoDel parameters
    target => pos_integer(),
    interval => pos_integer(),
    %% Capacity tracking
    max_in_flight => pos_integer(),
    %% Priority thresholds (percentage of max_in_flight)
    p1_threshold => 1..100,
    p2_threshold => 1..100,
    p3_threshold => 1..100
}.

-export_type([priority/0, opts/0]).

-record(state, {
    name :: atom(),
    %% CoDel state
    target :: pos_integer(),
    interval :: pos_integer(),
    first_above_time :: integer() | undefined,
    drop_next :: integer(),
    dropping :: boolean(),
    drop_count :: non_neg_integer(),
    %% Capacity
    max_in_flight :: pos_integer(),
    in_flight :: non_neg_integer(),
    %% Priority thresholds
    p1_threshold :: float(),
    p2_threshold :: float(),
    p3_threshold :: float(),
    %% Stats
    total_admitted :: non_neg_integer(),
    total_shed :: non_neg_integer(),
    recent_latencies :: queue:queue(non_neg_integer()),
    latency_count :: non_neg_integer()
}).

%%----------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------

start_link(Name, Opts) ->
    gen_server:start_link({local, Name}, ?MODULE, {Name, Opts}, []).

-spec admit(atom()) -> ok | {error, shed}.
admit(Name) ->
    admit(Name, 2).

-spec admit(atom(), priority()) -> ok | {error, shed}.
admit(Name, Priority) ->
    gen_server:call(Name, {admit, Priority}).

-spec complete(atom(), non_neg_integer()) -> ok.
complete(Name, DurationMs) ->
    gen_server:cast(Name, {complete, DurationMs}).

-spec status(atom()) -> map().
status(Name) ->
    gen_server:call(Name, status).

%%----------------------------------------------------------------------
%% gen_server callbacks
%%----------------------------------------------------------------------

init({Name, Opts}) ->
    State = #state{
        name = Name,
        target = maps:get(target, Opts, 5),
        interval = maps:get(interval, Opts, 100),
        first_above_time = undefined,
        drop_next = 0,
        dropping = false,
        drop_count = 0,
        max_in_flight = maps:get(max_in_flight, Opts, 1000),
        in_flight = 0,
        p1_threshold = maps:get(p1_threshold, Opts, 90) / 100,
        p2_threshold = maps:get(p2_threshold, Opts, 80) / 100,
        p3_threshold = maps:get(p3_threshold, Opts, 70) / 100,
        total_admitted = 0,
        total_shed = 0,
        recent_latencies = queue:new(),
        latency_count = 0
    },
    {ok, State}.

handle_call({admit, Priority}, _From, State) ->
    case should_admit(Priority, State) of
        true ->
            NewState = State#state{
                in_flight = State#state.in_flight + 1,
                total_admitted = State#state.total_admitted + 1
            },
            emit_admit(State#state.name, Priority, NewState#state.in_flight),
            {reply, ok, NewState};
        false ->
            NewState = State#state{
                total_shed = State#state.total_shed + 1
            },
            emit_shed(State#state.name, Priority, State#state.in_flight),
            {reply, {error, shed}, NewState}
    end;
handle_call(status, _From, State) ->
    #state{
        in_flight = InFlight,
        max_in_flight = Max,
        dropping = Dropping,
        total_admitted = Admitted,
        total_shed = Shed
    } = State,
    AvgLatency = avg_latency(State),
    {reply,
        #{
            in_flight => InFlight,
            max_in_flight => Max,
            utilization => InFlight / max(1, Max),
            dropping => Dropping,
            drop_count => State#state.drop_count,
            total_admitted => Admitted,
            total_shed => Shed,
            avg_latency_ms => AvgLatency
        },
        State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({complete, DurationMs}, State) ->
    NewState0 = State#state{
        in_flight = max(0, State#state.in_flight - 1)
    },
    NewState = update_codel(DurationMs, NewState0),
    {noreply, NewState};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%----------------------------------------------------------------------
%% Admission logic
%%----------------------------------------------------------------------

should_admit(0, _State) ->
    %% P0 (critical) — always admit
    true;
should_admit(Priority, State) ->
    #state{
        in_flight = InFlight,
        max_in_flight = Max,
        dropping = Dropping
    } = State,
    Utilization = InFlight / max(1, Max),
    Threshold = priority_threshold(Priority, State),
    case Utilization >= Threshold of
        true ->
            false;
        false ->
            %% CoDel: if we're in dropping mode, shed non-critical
            case Dropping andalso Priority > 0 of
                true -> false;
                false -> InFlight < Max
            end
    end.

priority_threshold(1, #state{p1_threshold = T}) -> T;
priority_threshold(2, #state{p2_threshold = T}) -> T;
priority_threshold(3, #state{p3_threshold = T}) -> T;
priority_threshold(_, _) -> 1.0.

%%----------------------------------------------------------------------
%% CoDel algorithm
%%----------------------------------------------------------------------

update_codel(DurationMs, State) ->
    #state{
        target = Target,
        interval = Interval,
        first_above_time = FirstAbove,
        dropping = Dropping,
        drop_count = DropCount
    } = State,
    Now = erlang:monotonic_time(millisecond),
    %% Track latency
    State1 = record_latency(DurationMs, State),
    case DurationMs < Target of
        true ->
            %% Sojourn time below target — reset
            State1#state{
                first_above_time = undefined,
                dropping = false
            };
        false when FirstAbove =:= undefined ->
            %% First time above target — start tracking
            State1#state{
                first_above_time = Now
            };
        false when not Dropping ->
            %% Check if we've been above target for an interval
            case Now - FirstAbove >= Interval of
                true ->
                    emit_codel_drop(State#state.name, DropCount + 1),
                    State1#state{
                        dropping = true,
                        drop_count = DropCount + 1,
                        drop_next = Now + control_interval(DropCount + 1, Interval)
                    };
                false ->
                    State1
            end;
        false ->
            %% Already dropping — check if we should continue
            case Now >= State#state.drop_next of
                true ->
                    NewCount = DropCount + 1,
                    State1#state{
                        drop_count = NewCount,
                        drop_next = Now + control_interval(NewCount, Interval)
                    };
                false ->
                    State1
            end
    end.

%% CoDel control law: interval / sqrt(count)
control_interval(Count, Interval) ->
    trunc(Interval / math:sqrt(Count)).

%%----------------------------------------------------------------------
%% Latency tracking
%%----------------------------------------------------------------------

record_latency(DurationMs, #state{recent_latencies = Q, latency_count = Count} = State) ->
    MaxEntries = 100,
    Q2 = queue:in(DurationMs, Q),
    case Count >= MaxEntries of
        true ->
            {_, Q3} = queue:out(Q2),
            State#state{recent_latencies = Q3};
        false ->
            State#state{recent_latencies = Q2, latency_count = Count + 1}
    end.

avg_latency(#state{latency_count = 0}) ->
    0;
avg_latency(#state{recent_latencies = Q, latency_count = Count}) ->
    Sum = queue:fold(fun(V, Acc) -> Acc + V end, 0, Q),
    Sum / Count.

%%----------------------------------------------------------------------
%% Telemetry
%%----------------------------------------------------------------------

emit_admit(Name, Priority, InFlight) ->
    telemetry:execute(
        [seki, shed, admit],
        #{in_flight => InFlight},
        #{name => Name, priority => Priority}
    ).

emit_shed(Name, Priority, InFlight) ->
    telemetry:execute(
        [seki, shed, shed],
        #{in_flight => InFlight},
        #{name => Name, priority => Priority}
    ).

emit_codel_drop(Name, DropCount) ->
    telemetry:execute(
        [seki, shed, codel_drop],
        #{drop_count => DropCount},
        #{name => Name}
    ).
