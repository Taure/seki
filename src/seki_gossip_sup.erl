-module(seki_gossip_sup).
-moduledoc false.

-behaviour(supervisor).

%% Holds the gossip process of each limiter on the `seki_backend_pg` backend,
%% each under a supervisor of its own (`seki_name_sup`) and known by the table
%% it gossips. The process that owns the table is not linked to it: a gossip
%% process that dies is restarted here, and the limiters stay as they are.

-export([start_link/0, start_gossip/2, stop_gossip/2]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% Without the application there is no supervisor to hold it, and the gossip
%% process is linked to its caller. With it, a gossip process is only ever
%% started under this supervisor: while the supervisor is itself being
%% restarted the start fails, and nothing is linked to the caller.
-spec start_gossip(ets:table(), map()) -> {ok, pid()} | {error, term()}.
start_gossip(Tab, Opts) ->
    case whereis(seki_sup) of
        undefined -> seki_pg_gossip:start_link(Opts);
        _Running -> supervised(Tab, Opts)
    end.

supervised(Tab, Opts) ->
    try
        seki_name_sup:start(?MODULE, #{
            id => Tab,
            start => {seki_pg_gossip, start_link, [Opts]},
            restart => transient,
            shutdown => 5000,
            significant => true
        })
    catch
        exit:Reason -> {error, Reason}
    end.

%% `Started` is the process as it was first started. It is only stopped here
%% when no supervisor holds it, and it may be gone by then.
-spec stop_gossip(ets:table(), pid()) -> ok.
stop_gossip(Tab, Started) ->
    try seki_name_sup:stop(?MODULE, Tab) of
        ok -> ok;
        {error, _NotHeld} -> stop_unsupervised(Started)
    catch
        exit:_NotRunning -> stop_unsupervised(Started)
    end.

stop_unsupervised(Gossip) ->
    try
        seki_pg_gossip:stop(Gossip)
    catch
        exit:_Gone -> ok
    end.

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },
    {ok, {SupFlags, []}}.
