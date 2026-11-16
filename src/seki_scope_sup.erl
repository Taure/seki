-module(seki_scope_sup).
-moduledoc false.

-behaviour(supervisor).

%% Holds the `pg` scopes that seki started. A scope that is already running,
%% such as one the application using seki started itself, is used as it is and
%% is never started here: its owner restarts it. A name that is registered for
%% anything else is refused: joining a group in it would wait for an answer
%% that never comes.

-export([start_link/0, ensure/1, running/1, held/1, own/1]).
-export([init/1]).

-define(TABLE_WAIT, 5).
-define(TABLE_LOOKS, 10).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec ensure(atom()) -> ok | {error, not_a_scope}.
ensure(Scope) ->
    case whereis(Scope) of
        undefined -> started(Scope);
        Registered -> scope_process(Scope, Registered)
    end.

-spec running(atom()) -> ok | {error, not_a_scope}.
running(Scope) ->
    scope_process(Scope, whereis(Scope)).

-spec held(atom()) -> boolean().
held(Scope) ->
    is_pid(held_scope(Scope)).

%% Without the application nothing holds a scope, and the one that was
%% started for a limiter is the limiter's to start again.
-spec own(atom()) -> boolean().
own(Scope) ->
    held(Scope) orelse whereis(seki_sup) =:= undefined.

%% A start fails when the name was taken since it was looked up, by another
%% caller starting the same scope or by something else, so whatever holds the
%% name now decides.
started(Scope) ->
    case start(Scope) of
        {ok, _Started} -> ok;
        {error, _NotStarted} -> scope_process(Scope, whereis(Scope))
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

%% A scope held here was started by `pg` and needs no second look. Anything
%% else has to be started as a scope and own the table `pg` names after it:
%% `pg` runs a scope as itself up to OTP 28 and as a `data_publisher` from
%% OTP 29, and on both the scope makes that table while it starts.
scope_process(Scope, Registered) when is_pid(Registered) ->
    case held_scope(Scope) =:= Registered orelse started_as_scope(Registered) of
        true -> owns_its_table(Scope, Registered, ?TABLE_LOOKS);
        false -> {error, not_a_scope}
    end;
scope_process(_Scope, _PortOrNothing) ->
    {error, not_a_scope}.

started_as_scope(Registered) ->
    case proc_lib:translate_initial_call(Registered) of
        {pg, init, 1} -> true;
        {data_publisher, init, 1} -> true;
        _SomethingElse -> false
    end.

%% The name is registered before the scope has made its table, so a scope
%% that is still starting is given a moment.
owns_its_table(Scope, Registered, Looks) ->
    case ets:info(Scope, owner) of
        Registered ->
            ok;
        _NotYet when Looks > 1 ->
            receive
            after ?TABLE_WAIT -> owns_its_table(Scope, Registered, Looks - 1)
            end;
        _NotItsTable ->
            {error, not_a_scope}
    end.

held_scope(Scope) ->
    try supervisor:which_children(?MODULE) of
        Children ->
            case lists:keyfind(Scope, 1, Children) of
                {Scope, Held, _Type, _Modules} -> Held;
                false -> undefined
            end
    catch
        exit:_NoSupervisor -> undefined
    end.

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },
    {ok, {SupFlags, []}}.
