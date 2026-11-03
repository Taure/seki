-module(seki_ets_worker).
-moduledoc false.

-behaviour(gen_server).

-export([
    start_link/1,
    names/0,
    publish_names/1,
    route/2,
    atomic_update/3
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2
]).

-define(NAMES_KEY, {?MODULE, names}).
-define(CALL_TIMEOUT, 1000).

-spec start_link(atom()) -> gen_server:start_ret().
start_link(Name) ->
    gen_server:start_link({local, Name}, ?MODULE, [], []).

-spec names() -> [atom()].
names() ->
    [
        list_to_atom("seki_ets_worker_" ++ integer_to_list(I))
     || I <- lists:seq(1, erlang:system_info(schedulers_online))
    ].

-spec publish_names([atom()]) -> ok.
publish_names(Names) ->
    persistent_term:put(?NAMES_KEY, list_to_tuple(Names)).

-spec route(ets:table(), term()) -> {worker, atom()} | local.
route(Tab, StorageKey) ->
    case persistent_term:get(?NAMES_KEY, undefined) of
        Names when is_tuple(Names), tuple_size(Names) > 0 ->
            {worker, element(erlang:phash2({Tab, StorageKey}, tuple_size(Names)) + 1, Names)};
        _ ->
            local
    end.

-spec atomic_update(ets:table(), term(), seki_ets:step()) -> {ok, term()} | {error, contention}.
atomic_update(Tab, StorageKey, Step) ->
    case route(Tab, StorageKey) of
        {worker, Name} -> call(Name, Tab, StorageKey, Step);
        local -> seki_ets:local_update(Tab, StorageKey, Step)
    end.

call(Name, Tab, StorageKey, Step) ->
    Deadline = erlang:monotonic_time(millisecond) + ?CALL_TIMEOUT,
    try call_worker(Name, {atomic_update, Deadline, Tab, StorageKey, Step}) of
        {raise, Class, Reason, Stacktrace} -> erlang:raise(Class, Reason, Stacktrace);
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, contention};
        exit:_ -> seki_ets:local_update(Tab, StorageKey, Step)
    end.

-spec call_worker(atom(), {atomic_update, integer(), ets:table(), term(), seki_ets:step()}) ->
    dynamic().
call_worker(Name, Request) ->
    gen_server:call(Name, Request, ?CALL_TIMEOUT).

init([]) ->
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
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

run(Tab, StorageKey, Step) ->
    try
        seki_ets:local_update(Tab, StorageKey, Step)
    catch
        Class:Reason:Stacktrace -> {raise, Class, Reason, Stacktrace}
    end.
