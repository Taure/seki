-module(seki_registry_keeper).
-moduledoc false.
-behaviour(gen_server).

%% Holds the registry's table while the registry is not running: it creates
%% the table, gives it to the registry and inherits it when the registry
%% dies. The names outlive a restart of the registry, and only the registry
%% ever writes them.

-export([start_link/0, claim/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, seki_registry).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec claim() -> ok | {error, term()}.
claim() ->
    case gen_server:call(?MODULE, claim) of
        ok -> ok;
        {error, Reason} -> {error, Reason}
    end.

-spec init([]) -> {ok, []}.
init([]) ->
    case ets:whereis(?TAB) of
        undefined -> new_table();
        _RegistryOwns -> seki_registry:keeper_restarted()
    end,
    {ok, []}.

-spec handle_call(term(), gen_server:from(), []) -> {reply, term(), []}.
handle_call(claim, {Caller, _Tag}, State) ->
    {reply, give(Caller, whereis(seki_registry)), State};
handle_call(Request, _From, State) ->
    ok = seki_unexpected:dropped(?MODULE, call, Request),
    {reply, {error, unknown_request}, State}.

-spec handle_cast(term(), []) -> {noreply, []}.
handle_cast(Message, State) ->
    ok = seki_unexpected:dropped(?MODULE, cast, Message),
    {noreply, State}.

-spec handle_info(term(), []) -> {noreply, []}.
handle_info({'ETS-TRANSFER', ?TAB, _Registry, ?TAB}, State) ->
    {noreply, State};
handle_info(Message, State) ->
    ok = seki_unexpected:dropped(?MODULE, info, Message),
    {noreply, State}.

-spec give(pid(), pid() | port() | undefined) -> ok | {error, not_the_registry | not_the_owner}.
give(Registry, Registry) ->
    case ets:whereis(?TAB) of
        undefined -> new_table();
        _Held -> ok
    end,
    try ets:give_away(?TAB, Registry, ?TAB) of
        true -> ok
    catch
        error:badarg -> {error, not_the_owner}
    end;
give(_Caller, _Registry) ->
    {error, not_the_registry}.

-spec new_table() -> ok.
new_table() ->
    _ = ets:new(?TAB, [
        named_table, protected, set, {read_concurrency, true}, {heir, self(), ?TAB}
    ]),
    ok.
