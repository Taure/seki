-module(seki_registry).
-moduledoc false.
-behaviour(gen_server).

%% Names that are not atoms, for the processes seki starts: breakers,
%% bulkheads, load shedders, adaptive limiters and health checkers.
%%
%% An atom is registered as it always was, `{local, Name}`. Any other term is
%% registered here, `{via, seki_registry, Name}`, so a breaker can be named
%% `{payments, Tenant}` without an atom per tenant.
%%
%% `seki_sup` owns the table and creates it before it starts this process. The
%% names therefore outlive a restart of the registry, which monitors whatever
%% the table holds when it starts.

-export([start_link/0, new_table/0, registration/1, server/1]).
-export([register_name/2, unregister_name/1, whereis_name/1, send/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, seki_registry).

-type via() :: {via, ?MODULE, term()}.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec new_table() -> ok.
new_table() ->
    _ = ets:new(?TAB, [named_table, public, set, {read_concurrency, true}]),
    ok.

%% What a process named `Name` is started with.
-spec registration(term()) -> {local, atom()} | via().
registration(Name) when is_atom(Name) -> {local, Name};
registration(Name) -> {via, ?MODULE, Name}.

%% What a process named `Name` is called with.
-spec server(term()) -> atom() | via().
server(Name) when is_atom(Name) -> Name;
server(Name) -> {via, ?MODULE, Name}.

-spec register_name(term(), pid()) -> yes | no.
register_name(Name, Pid) when is_pid(Pid) ->
    case gen_server:call(?MODULE, {register, Name, Pid}) of
        yes -> yes;
        _Taken -> no
    end.

-spec unregister_name(term()) -> ok.
unregister_name(Name) ->
    _ = gen_server:call(?MODULE, {unregister, Name}),
    ok.

-spec whereis_name(term()) -> pid() | undefined.
whereis_name(Name) ->
    case ets:lookup(?TAB, Name) of
        [{Name, Pid, _Monitor}] when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true -> Pid;
                false -> undefined
            end;
        _Unregistered ->
            undefined
    end.

-spec send(term(), term()) -> pid().
send(Name, Message) ->
    case whereis_name(Name) of
        Pid when is_pid(Pid) ->
            Pid ! Message,
            Pid;
        undefined ->
            exit({badarg, {Name, Message}})
    end.

%%----------------------------------------------------------------------
%% gen_server callbacks
%%----------------------------------------------------------------------

init([]) ->
    Names =
        #{
            monitored(Name, Pid) => Name
         || {Name, Pid, _Monitor} <:- ets:tab2list(?TAB), is_pid(Pid)
        },
    {ok, Names}.

handle_call({register, Name, Pid}, _From, Names) ->
    case whereis_name(Name) of
        undefined ->
            {reply, yes, (forgotten(Name, Names))#{monitored(Name, Pid) => Name}};
        _Registered ->
            {reply, no, Names}
    end;
handle_call({unregister, Name}, _From, Names) ->
    {reply, ok, forgotten(Name, Names)};
handle_call(_Request, _From, Names) ->
    {reply, {error, unknown_request}, Names}.

handle_cast(_Message, Names) ->
    {noreply, Names}.

handle_info({'DOWN', Monitor, process, _Pid, _Reason}, Names) ->
    case Names of
        #{Monitor := Name} -> {noreply, forgotten(Name, Monitor, Names)};
        #{} -> {noreply, Names}
    end;
handle_info(_Info, Names) ->
    {noreply, Names}.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

-spec monitored(term(), pid()) -> reference().
monitored(Name, Pid) ->
    Monitor = erlang:monitor(process, Pid),
    true = ets:insert(?TAB, {Name, Pid, Monitor}),
    Monitor.

-spec forgotten(term(), #{reference() => term()}) -> #{reference() => term()}.
forgotten(Name, Names) ->
    case ets:lookup(?TAB, Name) of
        [{Name, _Pid, Monitor}] when is_reference(Monitor) -> forgotten(Name, Monitor, Names);
        _Unregistered -> Names
    end.

%% Only the registration `Monitor` stands for: a name taken again since is
%% under another monitor and stays.
-spec forgotten(term(), reference(), #{reference() => term()}) -> #{reference() => term()}.
forgotten(Name, Monitor, Names) ->
    true = erlang:demonitor(Monitor, [flush]),
    true = ets:match_delete(?TAB, {Name, '_', Monitor}),
    maps:remove(Monitor, Names).
