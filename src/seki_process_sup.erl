-module(seki_process_sup).
-moduledoc false.

-behaviour(supervisor).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/0,
    start_child/3,
    stop_child/1,
    named/0
]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_child(module(), seki:name(), map()) -> {ok, pid()} | {error, term()}.
start_child(_Module, Pid, _Opts) when is_pid(Pid) ->
    {error, {invalid_name, Pid}};
start_child(Module, Name, Opts) ->
    ChildSpec = #{
        id => Name,
        start => {Module, start_link, [Name, Opts]},
        restart => transient,
        shutdown => 5000
    },
    case supervisor:start_child(?MODULE, ChildSpec) of
        {ok, Pid} = Ok when is_pid(Pid) ->
            ?LOG_INFO(
                #{
                    msg => process_started,
                    module => Module,
                    name => seki_name:label(Name),
                    pid => Pid
                },
                #{domain => [seki]}
            ),
            Ok;
        {error, Reason} = Err ->
            ?LOG_ERROR(
                #{
                    msg => process_start_failed,
                    module => Module,
                    name => seki_name:label(Name),
                    reason => Reason
                },
                #{domain => [seki]}
            ),
            Err
    end.

-spec stop_child(seki:name()) -> ok | {error, term()}.
stop_child(Name) ->
    case supervisor:terminate_child(?MODULE, Name) of
        ok ->
            case supervisor:delete_child(?MODULE, Name) of
                ok ->
                    ?LOG_INFO(
                        #{msg => process_stopped, name => seki_name:label(Name)},
                        #{domain => [seki]}
                    ),
                    ok;
                {error, Reason} = Err ->
                    ?LOG_ERROR(
                        #{
                            msg => process_delete_failed,
                            name => seki_name:label(Name),
                            reason => Reason
                        },
                        #{domain => [seki]}
                    ),
                    Err
            end;
        {error, Reason} = Err ->
            ?LOG_ERROR(
                #{msg => process_stop_failed, name => seki_name:label(Name), reason => Reason},
                #{domain => [seki]}
            ),
            Err
    end.

-spec named() -> [{seki:name(), pid()}].
named() ->
    seki_registry:named_children(?MODULE).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },
    {ok, {SupFlags, []}}.
