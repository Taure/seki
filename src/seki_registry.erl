-module(seki_registry).
-moduledoc false.
-behaviour(gen_server).

%% This process owns the table and is the only one to write it while it runs.
%% It takes the table from `seki_registry_keeper`, which inherits it back when
%% this process dies. The names therefore outlive a restart of the registry,
%% which monitors whatever the table holds when it starts.

-export([start_link/0, registration/1, server/1, named_children/1]).
-export([register_name/2, unregister_name/1, whereis_name/1, send/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, seki_registry).
-define(REGISTER_ATTEMPTS, 10).
-define(REGISTER_PAUSE, 5).

-type via() :: {via, ?MODULE, seki:name()}.
-type names() :: #{reference() => seki:name()}.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec registration(seki:name()) -> {local, atom()} | via().
registration(Name) when is_atom(Name) -> {local, Name};
registration(Name) when not is_pid(Name) -> {via, ?MODULE, Name}.

-spec server(seki:name() | pid()) -> atom() | pid() | via().
server(Name) when is_atom(Name) -> Name;
server(Pid) when is_pid(Pid) -> Pid;
server(Name) -> {via, ?MODULE, Name}.

%% A supervisor that starts named processes gives the supervisor of each its
%% name as its id, so it can say which names it holds, and that supervisor
%% which process it holds, when the table has been lost.
-spec named_children(atom()) -> [{seki:name(), pid()}].
named_children(Parent) ->
    try supervisor:which_children(Parent) of
        Children ->
            [
                {Name, Process}
             || {Name, Supervisor, _Type, _Modules} <- Children,
                is_pid(Supervisor),
                not is_atom(Name),
                {ok, Process} <- [seki_name_sup:process(Supervisor)]
            ]
    catch
        exit:_NotRunning -> []
    end.

%% Called by a process that is starting under its supervisor. A start that
%% fails is tried again at once and uses up the supervisor's restarts, so
%% while the registry is restarting the process waits for it, for 50 ms at
%% most.
-spec register_name(seki:name(), pid()) -> yes | no.
register_name(Name, Pid) when is_pid(Pid), node(Pid) =:= node() ->
    register_name(Name, Pid, ?REGISTER_ATTEMPTS).

-spec register_name(seki:name(), pid(), pos_integer()) -> yes | no.
register_name(Name, Pid, Attempts) ->
    try gen_server:call(?MODULE, {register, Name, Pid}) of
        yes -> yes;
        _Taken -> no
    catch
        exit:{Reason, _Call} when Reason =/= timeout, Attempts > 1 ->
            timer:sleep(?REGISTER_PAUSE),
            register_name(Name, Pid, Attempts - 1)
    end.

-spec unregister_name(seki:name()) -> ok.
unregister_name(Name) ->
    _ = gen_server:call(?MODULE, {unregister, Name}),
    ok.

-spec whereis_name(seki:name()) -> pid() | undefined.
whereis_name(Name) ->
    try ets:lookup(?TAB, Name) of
        [{Name, Pid, _Monitor}] when is_pid(Pid), node(Pid) =:= node() ->
            case is_process_alive(Pid) of
                true -> Pid;
                false -> undefined
            end;
        _Unregistered ->
            undefined
    catch
        %% No table: seki is not running, and nothing is registered.
        error:badarg -> undefined
    end.

-spec send(seki:name(), term()) -> pid().
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

-spec init([]) -> {ok, names()} | {stop, {no_table, term()}}.
init([]) ->
    case seki_registry_keeper:claim() of
        ok ->
            {ok, #{Monitor => Name || Row <- ets:tab2list(?TAB), {Monitor, Name} <- restore(Row)}};
        {error, Reason} ->
            {stop, {no_table, Reason}}
    end.

-spec handle_call(term(), gen_server:from(), names()) -> {reply, term(), names()}.
handle_call({register, Name, Pid}, _From, Names) when is_pid(Pid), node(Pid) =:= node() ->
    case whereis_name(Name) of
        undefined ->
            {reply, yes, Names#{monitor_name(Name, Pid) => Name}};
        _Registered ->
            {reply, no, Names}
    end;
handle_call({unregister, Name}, _From, Names) ->
    {reply, ok, forget(Name, Names)};
handle_call(Request, _From, Names) ->
    ok = seki_unexpected:dropped(?MODULE, call, Request),
    {reply, {error, unknown_request}, Names}.

-spec handle_cast(term(), names()) -> {noreply, names()}.
handle_cast(Message, Names) ->
    ok = seki_unexpected:dropped(?MODULE, cast, Message),
    {noreply, Names}.

-spec handle_info(term(), names()) -> {noreply, names()}.
handle_info({'DOWN', Monitor, process, _Pid, _Reason}, Names) ->
    case Names of
        #{Monitor := Name} -> {noreply, forget(Name, Monitor, Names)};
        #{} -> {noreply, Names}
    end;
handle_info({'ETS-TRANSFER', ?TAB, _Keeper, ?TAB}, Names) ->
    {noreply, Names};
handle_info(Message, Names) ->
    ok = seki_unexpected:dropped(?MODULE, info, Message),
    {noreply, Names}.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

%% A process that has since died is monitored too: its `DOWN` removes the row.
-spec restore(tuple()) -> [{reference(), seki:name()}].
restore({Name, Pid, _Monitor}) when is_pid(Pid), node(Pid) =:= node() ->
    [{monitor_name(Name, Pid), Name}];
restore(Unusable) ->
    true = ets:delete_object(?TAB, Unusable),
    [].

-spec monitor_name(seki:name(), pid()) -> reference().
monitor_name(Name, Pid) ->
    Monitor = erlang:monitor(process, Pid),
    true = ets:insert(?TAB, {Name, Pid, Monitor}),
    Monitor.

-spec forget(seki:name(), names()) -> names().
forget(Name, Names) ->
    case ets:lookup(?TAB, Name) of
        [{Name, _Pid, Monitor}] when is_reference(Monitor) -> forget(Name, Monitor, Names);
        _Unregistered -> Names
    end.

%% A name can be taken again before the `DOWN` of its last holder arrives.
%% Its row is then under a newer monitor, and stays.
-spec forget(seki:name(), reference(), names()) -> names().
forget(Name, Monitor, Names) ->
    true = erlang:demonitor(Monitor, [flush]),
    case ets:lookup(?TAB, Name) of
        [{Name, _Pid, Monitor}] -> true = ets:delete(?TAB, Name);
        _TakenAgain -> true
    end,
    maps:remove(Monitor, Names).
