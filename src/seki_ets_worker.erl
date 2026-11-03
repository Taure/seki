-module(seki_ets_worker).
-moduledoc false.

-behaviour(gen_server).

-export([
    start_link/1,
    names/0,
    atomic_update/3
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2
]).

-define(NAMES_KEY, {?MODULE, names}).
-define(CALL_TIMEOUT, 5000).

-spec start_link(atom()) -> gen_server:start_ret().
start_link(Name) ->
    gen_server:start_link({local, Name}, ?MODULE, [], []).

-spec names() -> [atom()].
names() ->
    [
        list_to_atom("seki_ets_worker_" ++ integer_to_list(I))
     || I <- lists:seq(1, erlang:system_info(schedulers_online))
    ].

-spec atomic_update(ets:table(), term(), seki_ets:step()) -> {ok, term()} | {error, contention}.
atomic_update(Tab, Key, Step) ->
    case persistent_term:get(?NAMES_KEY, undefined) of
        Names when is_tuple(Names) ->
            Name = element(erlang:phash2({Tab, Key}, tuple_size(Names)) + 1, Names),
            call(Name, Tab, Key, Step);
        undefined ->
            seki_ets:local_update(Tab, Key, Step)
    end.

call(Name, Tab, Key, Step) ->
    try call_worker(Name, {atomic_update, Tab, Key, Step}) of
        {raise, Class, Reason, Stacktrace} -> erlang:raise(Class, Reason, Stacktrace);
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, contention};
        exit:_ -> seki_ets:local_update(Tab, Key, Step)
    end.

-spec call_worker(atom(), {atomic_update, ets:table(), term(), seki_ets:step()}) -> dynamic().
call_worker(Name, Request) ->
    gen_server:call(Name, Request, ?CALL_TIMEOUT).

init([]) ->
    persistent_term:put(?NAMES_KEY, list_to_tuple(names())),
    {ok, #{}}.

handle_call({atomic_update, Tab, Key, Step}, _From, State) ->
    Reply =
        try
            seki_ets:local_update(Tab, Key, Step)
        catch
            Class:Reason:Stacktrace -> {raise, Class, Reason, Stacktrace}
        end,
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.
