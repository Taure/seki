-module(seki_breaker_sup).

-behaviour(supervisor).

-export([
    start_link/0,
    start_breaker/2,
    stop_breaker/1
]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_breaker(atom(), seki:breaker_opts()) -> {ok, pid()} | {error, term()}.
start_breaker(Name, Opts) ->
    ChildSpec = #{
        id => Name,
        start => {seki_breaker, start_link, [Name, Opts]},
        restart => transient,
        shutdown => 5000
    },
    supervisor:start_child(?MODULE, ChildSpec).

-spec stop_breaker(atom()) -> ok | {error, term()}.
stop_breaker(Name) ->
    case supervisor:terminate_child(?MODULE, Name) of
        ok ->
            supervisor:delete_child(?MODULE, Name);
        Error ->
            Error
    end.

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },
    {ok, {SupFlags, []}}.
