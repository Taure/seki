-module(seki_breaker_sup).
-moduledoc false.

-behaviour(supervisor).

-export([
    start_link/0,
    start_breaker/2,
    stop_breaker/1,
    named/0
]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_breaker(seki:name(), seki:breaker_opts()) -> {ok, pid()} | {error, term()}.
start_breaker(Pid, _Opts) when is_pid(Pid) ->
    {error, {invalid_name, Pid}};
start_breaker(Name, Opts) ->
    case seki_breaker:check_options(Opts) of
        ok -> start_child(Name, Opts);
        {error, Reason} -> {error, Reason}
    end.

start_child(Name, Opts) ->
    ChildSpec = #{
        id => Name,
        start => {seki_breaker, start_link, [Name, Opts]},
        restart => transient,
        shutdown => 5000
    },
    case supervisor:start_child(?MODULE, ChildSpec) of
        {ok, Breaker} when is_pid(Breaker) -> {ok, Breaker};
        {error, Reason} -> {error, Reason}
    end.

-spec stop_breaker(seki:name()) -> ok | {error, term()}.
stop_breaker(Name) ->
    case supervisor:terminate_child(?MODULE, Name) of
        ok ->
            supervisor:delete_child(?MODULE, Name);
        Error ->
            Error
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
