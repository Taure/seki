-module(seki_registry_sup).
-moduledoc false.

-behaviour(supervisor).

%% The keeper comes first and the registry dies with it. A table is therefore
%% only ever made by a keeper that starts with no registry running, which is
%% when it can put back the names the supervisors still hold.

-export([start_link/0]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => rest_for_one,
        intensity => 5,
        period => 10
    },
    Children = [
        #{
            id => seki_registry_keeper,
            start => {seki_registry_keeper, start_link, []}
        },
        #{
            id => seki_registry,
            start => {seki_registry, start_link, []}
        }
    ],
    {ok, {SupFlags, Children}}.
