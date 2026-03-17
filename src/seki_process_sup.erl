-module(seki_process_sup).
-moduledoc false.

-behaviour(supervisor).

-export([
    start_link/0,
    start_child/3,
    stop_child/1
]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_child(module(), atom(), map()) -> {ok, pid()} | {error, term()}.
start_child(Module, Name, Opts) ->
    ChildSpec = #{
        id => Name,
        start => {Module, start_link, [Name, Opts]},
        restart => transient,
        shutdown => 5000
    },
    case supervisor:start_child(?MODULE, ChildSpec) of
        {ok, Pid} = Ok ->
            logger:info(
                "Started ~p:~p (pid=~p)",
                [Module, Name, Pid],
                #{domain => [seki]}
            ),
            Ok;
        {error, Reason} = Err ->
            logger:error(
                "Failed to start ~p:~p: ~p",
                [Module, Name, Reason],
                #{domain => [seki]}
            ),
            Err
    end.

-spec stop_child(atom()) -> ok | {error, term()}.
stop_child(Name) ->
    case supervisor:terminate_child(?MODULE, Name) of
        ok ->
            case supervisor:delete_child(?MODULE, Name) of
                ok ->
                    logger:info(
                        "Stopped supervised process ~p",
                        [Name],
                        #{domain => [seki]}
                    ),
                    ok;
                {error, Reason} = Err ->
                    logger:error(
                        "Failed to delete child spec ~p: ~p",
                        [Name, Reason],
                        #{domain => [seki]}
                    ),
                    Err
            end;
        {error, Reason} = Err ->
            logger:error(
                "Failed to terminate ~p: ~p",
                [Name, Reason],
                #{domain => [seki]}
            ),
            Err
    end.

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },
    {ok, {SupFlags, []}}.
