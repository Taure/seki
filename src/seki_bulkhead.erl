-module(seki_bulkhead).

-moduledoc """
Concurrency limiter (bulkhead pattern) using atomics for lock-free counting.

Limits the number of concurrent executions. Monitors calling processes and
auto-releases slots on crash. Use `call/2` for automatic acquire/release
or `acquire/1` + `release/1` for manual control.

## Example

    seki_bulkhead:start_link(db_pool, #{max_concurrent => 25}).
    {ok, Result} = seki_bulkhead:call(db_pool, fun() -> db:query(Q) end).
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/2,
    check_options/1,
    acquire/1,
    acquire/2,
    release/1,
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

-record(state, {
    name :: seki:name(),
    max_concurrent :: pos_integer(),
    counter :: atomics:atomics_ref(),
    monitors :: #{reference() => pid()}
}).

%%----------------------------------------------------------------------
%% API
%%----------------------------------------------------------------------

-doc false.
-spec start_link(seki:name(), map()) -> gen_server:start_ret() | {error, seki_options:invalid()}.
start_link(Name, Opts) ->
    case check_options(Opts) of
        ok -> gen_server:start_link(seki_registry:registration(Name), ?MODULE, {Name, Opts}, []);
        {error, Reason} -> {error, Reason}
    end.

-doc false.
-spec check_options(term()) -> ok | {error, seki_options:invalid()}.
check_options(Opts) ->
    seki_options:check(Opts, [{max_concurrent, pos_integer}]).

-doc "Acquire a concurrency slot (non-blocking, returns immediately).".
-spec acquire(seki:name()) -> ok | {error, bulkhead_full}.
acquire(Name) ->
    acquire(Name, 0).

-doc "Acquire a concurrency slot with a timeout.".
-spec acquire(seki:name(), non_neg_integer()) -> ok | {error, bulkhead_full}.
acquire(Name, Timeout) ->
    CallTimeout = seki_number:larger(5000, Timeout + 1000),
    case gen_server:call(seki_registry:server(Name), {acquire, self()}, CallTimeout) of
        ok -> ok;
        {error, bulkhead_full} -> {error, bulkhead_full}
    end.

-doc "Release a previously acquired concurrency slot.".
-spec release(seki:name()) -> ok.
release(Name) ->
    gen_server:cast(seki_registry:server(Name), {release, self()}).

-doc "Execute a function with automatic acquire/release.".
-spec call(seki:name(), fun(() -> term())) -> {ok, term()} | {error, bulkhead_full}.
call(Name, Fun) ->
    call(Name, Fun, 5000).

-doc "Execute a function with automatic acquire/release and a timeout.".
-spec call(seki:name(), fun(() -> term()), non_neg_integer()) ->
    {ok, term()} | {error, bulkhead_full}.
call(Name, Fun, Timeout) ->
    case acquire(Name, Timeout) of
        ok ->
            try
                Result = Fun(),
                {ok, Result}
            after
                release(Name)
            end;
        {error, bulkhead_full} = Error ->
            Error
    end.

-doc "Get current bulkhead status (current, max, available slots).".
-spec status(seki:name()) ->
    #{current := non_neg_integer(), max := pos_integer(), available := non_neg_integer()}.
status(Name) ->
    status_reply(gen_server:call(seki_registry:server(Name), status)).

-spec status_reply(term()) ->
    #{current := non_neg_integer(), max := pos_integer(), available := non_neg_integer()}.
status_reply(#{current := Current, max := Max, available := Available}) when
    is_integer(Current), is_integer(Max), is_integer(Available)
->
    #{current => Current, max => Max, available => Available}.

%%----------------------------------------------------------------------
%% gen_server callbacks
%%----------------------------------------------------------------------

init({Name, Opts}) ->
    MaxConcurrent = maps:get(max_concurrent, Opts, 10),
    Counter = atomics:new(1, [{signed, false}]),
    {ok, #state{
        name = Name,
        max_concurrent = MaxConcurrent,
        counter = Counter,
        monitors = #{}
    }}.

handle_call({acquire, Pid}, _From, #state{counter = Counter, max_concurrent = Max} = State) ->
    Current = atomics:get(Counter, 1),
    case Current < Max of
        true ->
            atomics:add(Counter, 1, 1),
            MonRef = monitor(process, Pid),
            NewMonitors = maps:put(MonRef, Pid, State#state.monitors),
            emit_acquire(State#state.name, Current + 1, Max),
            {reply, ok, State#state{monitors = NewMonitors}};
        false ->
            ?LOG_WARNING(
                #{
                    msg => bulkhead_full,
                    name => seki_name:label(State#state.name),
                    max_concurrent => Max
                },
                #{domain => [seki]}
            ),
            emit_rejected(State#state.name, Max),
            {reply, {error, bulkhead_full}, State}
    end;
handle_call(status, _From, #state{counter = Counter, max_concurrent = Max} = State) ->
    Current = atomics:get(Counter, 1),
    {reply, #{current => Current, max => Max, available => Max - Current}, State};
handle_call(Request, _From, State) ->
    ok = seki_unexpected:dropped(?MODULE, call, Request),
    {reply, {error, unknown}, State}.

handle_cast({release, Pid}, State) ->
    {noreply, do_release_by_pid(Pid, State)};
handle_cast(Message, State) ->
    ok = seki_unexpected:dropped(?MODULE, cast, Message),
    {noreply, State}.

handle_info({'DOWN', MonRef, process, Pid, Reason}, State) ->
    case State#state.monitors of
        #{MonRef := _Holder} = Monitors ->
            ?LOG_WARNING(
                #{
                    msg => bulkhead_holder_died,
                    name => seki_name:label(State#state.name),
                    pid => Pid,
                    reason => Reason
                },
                #{domain => [seki]}
            ),
            atomics:sub(State#state.counter, 1, 1),
            Current = atomics:get(State#state.counter, 1),
            emit_release(State#state.name, Current, State#state.max_concurrent),
            {noreply, State#state{monitors = maps:remove(MonRef, Monitors)}};
        #{} ->
            {noreply, State}
    end;
handle_info(Message, State) ->
    ok = seki_unexpected:dropped(?MODULE, info, Message),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

do_release_by_pid(
    Pid, #state{monitors = Monitors, counter = Counter, name = Name, max_concurrent = Max} = State
) ->
    case find_monitor_by_pid(Pid, Monitors) of
        {ok, MonRef} ->
            demonitor(MonRef, [flush]),
            atomics:sub(Counter, 1, 1),
            Current = atomics:get(Counter, 1),
            emit_release(Name, Current, Max),
            State#state{monitors = maps:remove(MonRef, Monitors)};
        error ->
            State
    end.

find_monitor_by_pid(Pid, Monitors) ->
    case maps:to_list(maps:filter(fun(_K, V) -> V =:= Pid end, Monitors)) of
        [{MonRef, _} | _] -> {ok, MonRef};
        [] -> error
    end.

%%----------------------------------------------------------------------
%% Telemetry
%%----------------------------------------------------------------------

emit_acquire(Name, Current, Max) ->
    telemetry:execute(
        [seki, bulkhead, acquire],
        #{current => Current, available => Max - Current},
        #{name => Name}
    ).

emit_release(Name, Current, Max) ->
    telemetry:execute(
        [seki, bulkhead, release],
        #{current => Current, available => Max - Current},
        #{name => Name}
    ).

emit_rejected(Name, Max) ->
    telemetry:execute(
        [seki, bulkhead, rejected],
        #{current => Max, available => 0},
        #{name => Name}
    ).
