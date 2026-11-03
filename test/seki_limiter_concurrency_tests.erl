-module(seki_limiter_concurrency_tests).

-include_lib("eunit/include/eunit.hrl").

-export([atomic_update/3, handle_event/4]).

-define(LIMIT, 150).
-define(PROCS, 200).
-define(ROUNDS, 20).
-define(WINDOW, 3600000).

setup() ->
    {ok, _} = application:ensure_all_started(seki),
    ok.

cleanup(_) ->
    application:stop(seki),
    ok.

concurrent_check_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 60,
            {
                lists:flatten(io_lib:format("~p/~p allows exactly limit", [Algorithm, Backend])),
                fun() -> exactly_limit_allowed(Algorithm, Backend) end
            }}
     || Algorithm <:- [token_bucket, sliding_window, gcra, leaky_bucket],
        Backend <:- [seki_backend_ets, seki_backend_pg]
    ]}.

short_window_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 60,
            {
                lists:flatten(io_lib:format("~p/~p stays within rate", [Algorithm, Backend])),
                fun() -> stays_within_rate(Algorithm, Backend) end
            }}
     || Algorithm <:- [token_bucket, sliding_window, gcra, leaky_bucket],
        Backend <:- [seki_backend_ets, seki_backend_pg]
    ]}.

gossip_merge_during_checks_test_() ->
    {setup, fun setup/0, fun cleanup/1,
        {timeout, 60,
            {"stale gossip merges never overwrite local checks", fun gossip_merge_during_checks/0}}}.

fallback_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"backend without atomic_update needs an opt-in", fun nonatomic_backend/0},
        {"contention denies", fun contention_denies/0}
    ]}.

gossip_merge_during_checks() ->
    Name = conc_gossip,
    ok = seki:new_limiter(Name, #{
        algorithm => token_bucket,
        limit => ?LIMIT,
        window => ?WINDOW,
        backend => seki_backend_pg,
        backend_opts => #{table_name => Name, gossip_interval => ?WINDOW}
    }),
    Tab = pg_local_table(seki_limiter_registry:lookup(Name)),
    Allowed = [
        begin
            Key = {round, Round},
            Stale = {Key, {float(?LIMIT), erlang:monotonic_time(millisecond) - 1}},
            Merger = spawn_link(fun() -> merge_stale(Tab, Stale) end),
            Count = run_round(Name, Key),
            stop(Merger),
            Count
        end
     || Round <:- lists:seq(1, ?ROUNDS)
    ],
    seki:delete_limiter(Name),
    ?assertEqual(lists:duplicate(?ROUNDS, ?LIMIT), Allowed).

stop(Pid) ->
    unlink(Pid),
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    end.

pg_local_table({token_bucket, seki_backend_pg, BackendState, _}) when is_tuple(BackendState) ->
    element(2, BackendState).

merge_stale(Tab, Entry) ->
    seki_pg_gossip:merge_entries_for_test(Tab, [Entry]),
    merge_stale(Tab, Entry).

nonatomic_backend() ->
    Opts = #{
        algorithm => sliding_window,
        limit => 2,
        window => ?WINDOW,
        backend => seki_nonatomic_backend,
        backend_opts => #{table_name => conc_nonatomic}
    },
    ?assertEqual(
        {error, {backend_not_atomic, seki_nonatomic_backend}},
        seki:new_limiter(conc_nonatomic, Opts)
    ),
    ok = seki:new_limiter(conc_nonatomic, Opts#{allow_non_atomic => true}),
    {allow, #{remaining := 1}} = seki:check(conc_nonatomic, key),
    {allow, #{remaining := 0}} = seki:check(conc_nonatomic, key),
    {deny, _} = seki:check(conc_nonatomic, key),
    seki:delete_limiter(conc_nonatomic).

contention_denies() ->
    Config = #{limit => 10, window => 1000, emission_interval => 100.0, burst_tolerance => 900.0},
    ok = telemetry:attach(
        contention_test, [seki, rate_limit, contention], fun ?MODULE:handle_event/4, self()
    ),
    try
        ?assertEqual(
            {deny, #{retry_after => 1}},
            seki_algorithm:check(gcra, ?MODULE, undefined, key, 1, 0, Config)
        ),
        receive
            {contention, Measurements, Metadata} ->
                ?assertEqual(#{count => 1}, Measurements),
                ?assertEqual(#{key => key}, Metadata)
        after 1000 -> ?assert(false)
        end
    after
        telemetry:detach(contention_test)
    end.

handle_event([seki, rate_limit, contention], Measurements, Metadata, Pid) ->
    Pid ! {contention, Measurements, Metadata}.

atomic_update(_State, _Key, _Step) ->
    {error, contention}.

exactly_limit_allowed(Algorithm, Backend) ->
    Name = list_to_atom(
        lists:flatten(io_lib:format("conc_~p_~p", [Algorithm, Backend]))
    ),
    ok = seki:new_limiter(Name, #{
        algorithm => Algorithm,
        limit => ?LIMIT,
        window => ?WINDOW,
        backend => Backend,
        backend_opts => #{table_name => Name, gossip_interval => ?WINDOW}
    }),
    Allowed = [run_round(Name, {round, Round}) || Round <:- lists:seq(1, ?ROUNDS)],
    seki:delete_limiter(Name),
    ?assertEqual(lists:duplicate(?ROUNDS, ?LIMIT), Allowed).

stays_within_rate(Algorithm, Backend) ->
    Name = list_to_atom(
        lists:flatten(io_lib:format("rate_~p_~p", [Algorithm, Backend]))
    ),
    Window = 1000,
    ok = seki:new_limiter(Name, #{
        algorithm => Algorithm,
        limit => ?LIMIT,
        window => Window,
        backend => Backend,
        backend_opts => #{table_name => Name, gossip_interval => ?WINDOW}
    }),
    Parent = self(),
    Start = erlang:monotonic_time(millisecond),
    End = Start + 2000,
    Pids = [
        spawn_link(fun() -> Parent ! {allowed, self(), hammer(Name, End, 0)} end)
     || _ <:- lists:seq(1, ?PROCS)
    ],
    Allowed = lists:sum([
        receive
            {allowed, Pid, Count} -> Count
        end
     || Pid <:- Pids
    ]),
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    seki:delete_limiter(Name),
    Ceiling = ?LIMIT + ?LIMIT * Elapsed div Window + 1,
    ?assertMatch(N when N =< Ceiling, Allowed).

hammer(Name, End, Count) ->
    case erlang:monotonic_time(millisecond) >= End of
        true ->
            Count;
        false ->
            case seki:check(Name, hot) of
                {allow, _} -> hammer(Name, End, Count + 1);
                {deny, _} -> hammer(Name, End, Count)
            end
    end.

run_round(Name, Key) ->
    Parent = self(),
    Pids = [
        spawn_link(fun() ->
            receive
                go -> ok
            end,
            Parent ! {result, self(), seki:check(Name, Key)}
        end)
     || _ <:- lists:seq(1, ?PROCS)
    ],
    _ = [Pid ! go || Pid <:- Pids],
    Results = [
        receive
            {result, Pid, Result} -> Result
        end
     || Pid <:- Pids
    ],
    length([Result || Result <:- Results, element(1, Result) =:= allow]).
