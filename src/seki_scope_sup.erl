-module(seki_scope_sup).
-moduledoc false.

-behaviour(supervisor).

%% Holds the `pg` scopes that seki started. A scope that is already running,
%% such as one the application using seki started itself, is used as it is. A
%% name that is registered for anything else is refused: joining a group in it
%% would wait for an answer that never comes.

-export([start_link/0, ensure/1]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec ensure(atom()) -> ok | {error, not_a_scope}.
ensure(Scope) ->
    case whereis(Scope) of
        undefined -> started(Scope);
        Registered -> scope_process(Registered)
    end.

%% A start fails when the name was taken since it was looked up, by another
%% caller starting the same scope or by something else, so whatever holds the
%% name now decides.
started(Scope) ->
    case start(Scope) of
        {ok, _Started} -> ok;
        {error, _NotStarted} -> scope_process(whereis(Scope))
    end.

%% Without the application there is no supervisor to hold the scope. With it,
%% a scope is only ever started under this supervisor: while the supervisor
%% is itself being restarted nothing is started, and the caller is refused.
start(Scope) ->
    case whereis(seki_sup) of
        undefined -> pg:start(Scope);
        _Running -> supervised(Scope)
    end.

supervised(Scope) ->
    try
        supervisor:start_child(?MODULE, #{id => Scope, start => {pg, start_link, [Scope]}})
    catch
        exit:Reason -> {error, Reason}
    end.

scope_process(Registered) when is_pid(Registered) ->
    case proc_lib:translate_initial_call(Registered) of
        {pg, init, 1} -> ok;
        _SomethingElse -> {error, not_a_scope}
    end;
scope_process(_PortOrNothing) ->
    {error, not_a_scope}.

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },
    {ok, {SupFlags, []}}.
