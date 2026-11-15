-module(seki_name_sup).
-moduledoc false.

-behaviour(supervisor).

%% The supervisor of one named process. `seki_breaker_sup`, `seki_process_sup`
%% and `seki_gossip_sup` hold one of these for each name, and it holds the
%% process. A process that keeps crashing uses up the restarts of its own
%% supervisor only: this one gives up, and as a temporary child it is then
%% removed without costing the supervisor above it a restart. Every other
%% name is left as it was.
%%
%% The process is started as a child after this supervisor is up, inside the
%% call that starts the supervisor, so a start that fails comes back as the
%% supervisor of the process reports it.

-export([start/2, stop/2, process/1, start_link/1]).
-export([init/1]).

-define(RESTARTS, 3).
-define(PERIOD, 10).

-type process() :: #{
    id := term(),
    start := {module(), atom(), [term()]},
    restart := transient,
    shutdown := timeout(),
    significant => boolean()
}.

-export_type([process/0]).

-spec start(atom(), process()) -> {ok, pid()} | {error, term()}.
start(Parent, #{id := Id} = Process) ->
    Spec = #{
        id => Id,
        start => {?MODULE, start_link, [Process]},
        restart => temporary,
        shutdown => infinity,
        type => supervisor
    },
    case supervisor:start_child(Parent, Spec) of
        {ok, _Supervisor, Started} when is_pid(Started) ->
            {ok, Started};
        {error, {already_started, Supervisor}} when is_pid(Supervisor) ->
            case process(Supervisor) of
                {ok, Running} -> {error, {already_started, Running}};
                not_running -> {error, already_present};
                %% It went after the supervisor above answered, which will
                %% have dropped it by the time it is asked again.
                gone -> start(Parent, Process)
            end;
        {error, {{not_started, Reason}, _Spec}} ->
            {error, Reason};
        {error, Reason} ->
            {error, Reason}
    end.

-spec stop(atom(), term()) -> ok | {error, term()}.
stop(Parent, Id) ->
    supervisor:terminate_child(Parent, Id).

-spec process(pid()) -> {ok, pid()} | not_running | gone.
process(Supervisor) ->
    try supervisor:which_children(Supervisor) of
        [{_Id, Process, _Type, _Modules}] when is_pid(Process) -> {ok, Process};
        _NotRunning -> not_running
    catch
        exit:_Gone -> gone
    end.

-spec start_link(process()) -> {ok, pid(), pid()} | {error, {not_started, term()}}.
start_link(Process) ->
    {ok, Supervisor} = supervisor:start_link(?MODULE, []),
    case supervisor:start_child(Supervisor, Process) of
        {ok, Started} when is_pid(Started) ->
            {ok, Supervisor, Started};
        {error, Reason} ->
            true = unlink(Supervisor),
            ok = proc_lib:stop(Supervisor, shutdown, infinity),
            {error, {not_started, Reason}}
    end.

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => ?RESTARTS,
        period => ?PERIOD,
        auto_shutdown => any_significant
    },
    {ok, {SupFlags, []}}.
