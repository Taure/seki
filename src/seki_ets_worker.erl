-module(seki_ets_worker).
-moduledoc false.

-behaviour(gen_server).

-export([
    start_link/1,
    child_specs/0,
    route/2,
    atomic_update/3
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).

-define(COUNT_KEY, {?MODULE, count}).
-define(CALL_TIMEOUT, 1000).

-spec start_link(pos_integer()) -> gen_server:start_ret().
start_link(Index) ->
    gen_server:start_link(?MODULE, Index, []).

%% One worker per scheduler. Each publishes its pid under its own key when it
%% starts, so a restart replaces one pid: a term of one word, which costs no
%% global garbage collection to replace.
-spec child_specs() -> [supervisor:child_spec()].
child_specs() ->
    Count = erlang:system_info(schedulers_online),
    ok = persistent_term:put(?COUNT_KEY, Count),
    [
        #{id => {?MODULE, Index}, start => {?MODULE, start_link, [Index]}}
     || Index <- lists:seq(1, Count)
    ].

-spec route(ets:table(), term()) -> {worker, pid()} | local.
route(Tab, StorageKey) ->
    case persistent_term:get(?COUNT_KEY, 0) of
        Count when is_integer(Count), Count > 0 ->
            worker(erlang:phash2({Tab, StorageKey}, Count) + 1);
        _ ->
            local
    end.

worker(Index) ->
    case persistent_term:get({?MODULE, Index}, undefined) of
        Worker when is_pid(Worker) -> {worker, Worker};
        _ -> local
    end.

-spec atomic_update(ets:table(), term(), seki_ets:step()) -> {ok, term()} | {error, contention}.
atomic_update(Tab, StorageKey, Step) ->
    case route(Tab, StorageKey) of
        {worker, Worker} -> call(Worker, Tab, StorageKey, Step);
        local -> seki_ets:local_update(Tab, StorageKey, Step)
    end.

%% The pid of a worker that died stays published until its successor starts.
%% A call to it exits at once, and the caller then runs the step itself.
call(Worker, Tab, StorageKey, Step) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CALL_TIMEOUT,
    try call_worker(Worker, {atomic_update, Deadline, Tab, StorageKey, Step}) of
        {raise, Class, Reason, Stacktrace} -> erlang:raise(Class, Reason, Stacktrace);
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, contention};
        exit:_ -> seki_ets:local_update(Tab, StorageKey, Step)
    end.

-spec call_worker(pid(), {atomic_update, integer(), ets:table(), term(), seki_ets:step()}) ->
    dynamic().
call_worker(Worker, Request) ->
    gen_server:call(Worker, Request, ?CALL_TIMEOUT).

init(Index) ->
    ok = persistent_term:put({?MODULE, Index}, self()),
    {ok, #{}}.

%% A caller past its deadline has already been denied, so running its step
%% would consume capacity for a request that was turned away.
handle_call({atomic_update, Deadline, Tab, StorageKey, Step}, _From, State) ->
    Reply =
        case erlang:monotonic_time(millisecond) >= Deadline of
            true -> {error, contention};
            false -> run(Tab, StorageKey, Step)
        end,
    {reply, Reply, State};
handle_call(Request, _From, State) ->
    ok = seki_unexpected:dropped(?MODULE, call, Request),
    {reply, {error, unknown_request}, State}.

handle_cast(Message, State) ->
    ok = seki_unexpected:dropped(?MODULE, cast, Message),
    {noreply, State}.

handle_info(Message, State) ->
    ok = seki_unexpected:dropped(?MODULE, info, Message),
    {noreply, State}.

run(Tab, StorageKey, Step) ->
    try
        seki_ets:local_update(Tab, StorageKey, Step)
    catch
        Class:Reason:Stacktrace -> {raise, Class, Reason, Stacktrace}
    end.
