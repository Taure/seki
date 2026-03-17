-module(seki_sup).
-moduledoc false.

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },
    Children = [
        #{
            id => seki_breaker_sup,
            start => {seki_breaker_sup, start_link, []},
            type => supervisor
        },
        #{
            id => seki_process_sup,
            start => {seki_process_sup, start_link, []},
            type => supervisor
        },
        #{
            id => seki_limiter_registry,
            start => {seki_limiter_registry, start_link, []}
        }
    ],
    {ok, {SupFlags, Children}}.
