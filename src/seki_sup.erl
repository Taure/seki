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
        | ets_workers()
    ],
    {ok, {SupFlags, Children}}.

ets_workers() ->
    Names = seki_ets_worker:names(),
    ok = seki_ets_worker:publish_names(Names),
    [#{id => Name, start => {seki_ets_worker, start_link, [Name]}} || Name <- Names].
