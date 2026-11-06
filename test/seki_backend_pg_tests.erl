-module(seki_backend_pg_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(seki),
    ok.

cleanup(_) ->
    application:stop(seki),
    ok.

pg_backend_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"basic get/put", fun basic_get_put/0},
        {"update with default", fun update_default/0},
        {"delete key", fun delete_key/0},
        {"rate limiting through pg backend", fun rate_limit_through_pg/0},
        {"gossip merge - sliding window same window", fun merge_sliding_same/0},
        {"gossip merge - sliding window newer window", fun merge_sliding_newer/0},
        {"gossip merge - token bucket", fun merge_token_bucket/0},
        {"gossip merge - GCRA", fun merge_gcra/0},
        {"gossip merge - GCRA float TAT", fun merge_gcra_float/0}
    ]}.

basic_get_put() ->
    {ok, State} = seki_backend_pg:init(#{table_name => pg_test_1, gossip_interval => 60000}),
    ?assertEqual(not_found, seki_backend_pg:get(State, key1)),
    ok = seki_backend_pg:put(State, key1, value1),
    ?assertEqual({ok, value1}, seki_backend_pg:get(State, key1)),
    seki_backend_pg:terminate(State).

update_default() ->
    {ok, State} = seki_backend_pg:init(#{table_name => pg_test_2, gossip_interval => 60000}),
    {ok, 1} = seki_backend_pg:update(State, counter, fun(V) -> V + 1 end, 0),
    {ok, 2} = seki_backend_pg:update(State, counter, fun(V) -> V + 1 end, 0),
    ?assertEqual({ok, 2}, seki_backend_pg:get(State, counter)),
    seki_backend_pg:terminate(State).

delete_key() ->
    {ok, State} = seki_backend_pg:init(#{table_name => pg_test_3, gossip_interval => 60000}),
    ok = seki_backend_pg:put(State, key1, value1),
    ?assertEqual({ok, value1}, seki_backend_pg:get(State, key1)),
    ok = seki_backend_pg:delete(State, key1),
    ?assertEqual(not_found, seki_backend_pg:get(State, key1)),
    seki_backend_pg:terminate(State).

rate_limit_through_pg() ->
    ok = seki:new_limiter(pg_limiter, #{
        algorithm => sliding_window,
        limit => 5,
        window => 60000,
        backend => seki_backend_pg,
        backend_opts => #{table_name => pg_test_4, gossip_interval => 60000}
    }),
    {allow, _} = seki:check(pg_limiter, user1),
    {allow, _} = seki:check(pg_limiter, user1),
    {allow, _} = seki:check(pg_limiter, user1),
    {allow, _} = seki:check(pg_limiter, user1),
    {allow, _} = seki:check(pg_limiter, user1),
    {deny, _} = seki:check(pg_limiter, user1),
    seki:delete_limiter(pg_limiter).

%% Test gossip gen_server directly
gossip_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"gossip start and stop", fun gossip_start_stop/0},
        {"gossip receives merge cast", fun gossip_merge_cast/0},
        {"gossip broadcasts to peers", fun gossip_broadcast/0}
    ]}.

gossip_start_stop() ->
    ok = ensure_pg_scope(seki_pg),
    Tab = ets:new(gossip_test_1, [set, public]),
    {ok, Pid} = seki_pg_gossip:start_link(#{
        scope => seki_pg,
        group => gossip_test_group_1,
        tab => Tab,
        interval => 60000
    }),
    ?assert(is_process_alive(Pid)),
    %% Should have joined the pg group
    Members = pg:get_members(seki_pg, gossip_test_group_1),
    ?assert(lists:member(Pid, Members)),
    seki_pg_gossip:stop(Pid),
    ?assertNot(is_process_alive(Pid)),
    ets:delete(Tab).

gossip_merge_cast() ->
    ok = ensure_pg_scope(seki_pg),
    Tab = ets:new(gossip_test_2, [set, public]),
    Now = erlang:monotonic_time(millisecond),
    ets:insert(Tab, {key1, Now + 100}),
    {ok, Pid} = seki_pg_gossip:start_link(#{
        scope => seki_pg,
        group => gossip_test_group_2,
        tab => Tab,
        interval => 60000,
        algorithm => gcra
    }),
    %% Send merge cast with a higher GCRA TAT, relative to the sender's now
    gen_server:cast(Pid, {seki_gossip, 2, gcra, [{key1, 200}]}),
    {error, unknown} = gen_server:call(Pid, sync),
    [{key1, TAT}] = ets:lookup(Tab, key1),
    ?assert(TAT >= Now + 200),
    seki_pg_gossip:stop(Pid),
    ets:delete(Tab).

gossip_broadcast() ->
    ok = ensure_pg_scope(seki_pg),
    Tab1 = ets:new(gossip_test_3a, [set, public]),
    Tab2 = ets:new(gossip_test_3b, [set, public]),
    ets:insert(Tab1, {key1, 500}),
    {ok, Pid1} = seki_pg_gossip:start_link(#{
        scope => seki_pg,
        group => gossip_test_group_3,
        tab => Tab1,
        interval => 50
    }),
    {ok, Pid2} = seki_pg_gossip:start_link(#{
        scope => seki_pg,
        group => gossip_test_group_3,
        tab => Tab2,
        interval => 60000
    }),
    ?assertEqual([{key1, 500}], wait_for(Tab2, key1, 2000)),
    seki_pg_gossip:stop(Pid1),
    seki_pg_gossip:stop(Pid2),
    ets:delete(Tab1),
    ets:delete(Tab2).

wait_for(Tab, Key, Timeout) when Timeout =< 0 ->
    ets:lookup(Tab, Key);
wait_for(Tab, Key, Timeout) ->
    case ets:lookup(Tab, Key) of
        [] ->
            timer:sleep(10),
            wait_for(Tab, Key, Timeout - 10);
        Found ->
            Found
    end.

ensure_pg_scope(Scope) ->
    case pg:start(Scope) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

%% Test merge logic directly
merge_sliding_same() ->
    Tab = ets:new(merge_test_1, [set, public]),
    %% Local: 10 prev, 5 current, window start 1000
    ets:insert(Tab, {key1, {10, 5, 1000}}),
    %% Remote has higher counts in same window
    Remote = [{key1, {12, 8, 1000}}],
    seki_pg_gossip:merge_entries_for_test(Tab, Remote),
    [{key1, {P, C, W}}] = ets:lookup(Tab, key1),
    ?assertEqual(1000, W),
    ?assertEqual(12, P),
    ?assertEqual(8, C),
    ets:delete(Tab).

merge_sliding_newer() ->
    Tab = ets:new(merge_test_2, [set, public]),
    %% Local: window start 1000
    ets:insert(Tab, {key1, {10, 5, 1000}}),
    %% Remote has newer window
    Remote = [{key1, {5, 3, 2000}}],
    seki_pg_gossip:merge_entries_for_test(Tab, Remote),
    [{key1, {P, C, W}}] = ets:lookup(Tab, key1),
    ?assertEqual(2000, W),
    ?assertEqual(5, P),
    ?assertEqual(3, C),
    ets:delete(Tab).

merge_token_bucket() ->
    Tab = ets:new(merge_test_3, [set, public]),
    %% Local: 8.0 tokens at time 1000
    ets:insert(Tab, {key1, {8.0, 1000}}),
    %% Remote: 5.0 tokens at time 1000 (more consumed)
    Remote = [{key1, {5.0, 1000}}],
    seki_pg_gossip:merge_entries_for_test(Tab, Remote),
    [{key1, {Tokens, _}}] = ets:lookup(Tab, key1),
    ?assertEqual(5.0, Tokens),
    ets:delete(Tab).

merge_gcra() ->
    Tab = ets:new(merge_test_4, [set, public]),
    %% Local TAT
    ets:insert(Tab, {key1, 1000}),
    %% Remote TAT (higher = more limited)
    Remote = [{key1, 1500}],
    seki_pg_gossip:merge_entries_for_test(Tab, Remote),
    [{key1, TAT}] = ets:lookup(Tab, key1),
    ?assertEqual(1500, TAT),
    ets:delete(Tab).

merge_gcra_float() ->
    Tab = ets:new(merge_test_5, [set, public]),
    ets:insert(Tab, {key1, 1000.5}),
    seki_pg_gossip:merge_entries_for_test(Tab, [{key1, 1500.25}]),
    ?assertEqual([{key1, 1500.25}], ets:lookup(Tab, key1)),
    seki_pg_gossip:merge_entries_for_test(Tab, [{key1, 1200}]),
    ?assertEqual([{key1, 1500.25}], ets:lookup(Tab, key1)),
    ets:delete(Tab).

%% Gossip isolation and clock tests

gossip_isolation_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {timeout, 30, {"default groups keep limiters apart", fun default_groups_are_per_limiter/0}},
        {"relative timestamps are rebased to the local clock", fun relative_entry_is_rebased/0},
        {"0.4.3 gossip messages are ignored", fun old_format_is_ignored/0},
        {"bucket timestamps are rebased on receive", fun bucket_entries_are_rebased/0},
        {"window starts are rebased on receive", fun window_entry_is_rebased/0},
        {"timestamps leave relative to the sender", fun sent_entries_are_relative/0},
        {"windows less than one window apart merge counts", fun close_windows_merge_counts/0},
        {"windows a full window apart take the newer", fun distant_windows_take_newer/0},
        {"values outside a limiter are sent as they are", fun standalone_values_are_verbatim/0},
        {"gossip for another algorithm is ignored", fun other_algorithm_is_ignored/0}
    ]}.

default_groups_are_per_limiter() ->
    ok = seki:new_limiter(strict_login, #{
        algorithm => gcra,
        limit => 5,
        window => 3600000,
        backend => seki_backend_pg,
        backend_opts => #{gossip_interval => 50}
    }),
    ok = seki:new_limiter(loose_api, #{
        algorithm => gcra,
        limit => 1000,
        window => 1000,
        backend => seki_backend_pg,
        backend_opts => #{gossip_interval => 50}
    }),
    Key = {10, 0, 0, 7},
    {allow, _} = seki:check(loose_api, Key),
    _ = [seki:check(strict_login, Key) || _ <:- lists:seq(1, 6)],
    {deny, _} = seki:check(strict_login, Key),
    timer:sleep(300),
    Result = seki:check(loose_api, Key),
    seki:delete_limiter(strict_login),
    seki:delete_limiter(loose_api),
    ?assertMatch({allow, _}, Result).

relative_entry_is_rebased() ->
    {Gossip, State} = gossip_limiter(rebase_gcra),
    Tau = 900.0,
    Before = erlang:monotonic_time(millisecond),
    gen_server:cast(Gossip, {seki_gossip, 2, gcra, [{key, Tau}]}),
    {error, unknown} = gen_server:call(Gossip, sync),
    After = erlang:monotonic_time(millisecond),
    {ok, TAT} = seki_backend_pg:get(State, key),
    seki:delete_limiter(rebase_gcra),
    ?assert(TAT >= Before + Tau),
    ?assert(TAT =< After + Tau).

old_format_is_ignored() ->
    {Gossip, State} = gossip_limiter(old_format_gcra),
    gen_server:cast(Gossip, {merge, [{key, erlang:monotonic_time(millisecond) + 3600000}]}),
    {error, unknown} = gen_server:call(Gossip, sync),
    Result = seki_backend_pg:get(State, key),
    seki:delete_limiter(old_format_gcra),
    ?assertEqual(not_found, Result).

bucket_entries_are_rebased() ->
    _ = [
        begin
            Name = list_to_atom("rebase_" ++ atom_to_list(Algorithm)),
            {Gossip, State} = gossip_limiter(Name, Algorithm),
            Before = erlang:monotonic_time(millisecond),
            gen_server:cast(Gossip, {seki_gossip, 2, Algorithm, [{k, {5.0, -100}}]}),
            {error, unknown} = gen_server:call(Gossip, sync),
            After = erlang:monotonic_time(millisecond),
            {ok, {5.0, Timestamp}} = seki_backend_pg:get(State, k),
            seki:delete_limiter(Name),
            ?assert(Timestamp >= Before - 100 andalso Timestamp =< After - 100)
        end
     || Algorithm <:- [token_bucket, leaky_bucket]
    ],
    ok.

window_entry_is_rebased() ->
    {Gossip, State} = gossip_limiter(rebase_window, sliding_window),
    Before = erlang:monotonic_time(millisecond),
    gen_server:cast(Gossip, {seki_gossip, 2, sliding_window, [{k, {1, 2, -500}}]}),
    {error, unknown} = gen_server:call(Gossip, sync),
    After = erlang:monotonic_time(millisecond),
    {ok, {1, 2, WinStart}} = seki_backend_pg:get(State, k),
    seki:delete_limiter(rebase_window),
    ?assert(WinStart >= Before - 500 andalso WinStart =< After - 500).

sent_entries_are_relative() ->
    _ = [
        begin
            Name = list_to_atom("send_" ++ atom_to_list(Algorithm)),
            {Gossip, State} = gossip_limiter(Name, Algorithm),
            Now = erlang:monotonic_time(millisecond),
            ok = seki_backend_pg:put(State, k, Value(Now - 100)),
            Entries = capture_gossip(Name, Gossip, Algorithm),
            seki:delete_limiter(Name),
            [{k, Encoded}] = Entries,
            Offset = Timestamp(Encoded),
            ?assert(Offset =< -100 andalso Offset > -1100)
        end
     || {Algorithm, Value, Timestamp} <:- [
            {token_bucket, fun(T) -> {5.0, T} end, fun({_, T}) -> T end},
            {leaky_bucket, fun(T) -> {5.0, T} end, fun({_, T}) -> T end},
            {sliding_window, fun(T) -> {1, 2, T} end, fun({_, _, T}) -> T end},
            {gcra, fun(T) -> T end, fun(T) -> T end}
        ]
    ],
    ok.

close_windows_merge_counts() ->
    {Gossip, State} = gossip_limiter(close_windows, sliding_window),
    WinStart = erlang:monotonic_time(millisecond),
    ok = seki_backend_pg:put(State, k, {1, 5, WinStart}),
    gen_server:cast(Gossip, {seki_gossip, 2, sliding_window, [{k, {2, 3, 10}}]}),
    {error, unknown} = gen_server:call(Gossip, sync),
    Result = seki_backend_pg:get(State, k),
    seki:delete_limiter(close_windows),
    ?assertEqual({ok, {2, 5, WinStart}}, Result).

distant_windows_take_newer() ->
    {Gossip, State} = gossip_limiter(distant_windows, sliding_window),
    WinStart = erlang:monotonic_time(millisecond),
    ok = seki_backend_pg:put(State, k, {1, 5, WinStart}),
    gen_server:cast(Gossip, {seki_gossip, 2, sliding_window, [{k, {2, 3, 2000}}]}),
    {error, unknown} = gen_server:call(Gossip, sync),
    {ok, {2, 3, RemoteStart}} = seki_backend_pg:get(State, k),
    seki:delete_limiter(distant_windows),
    ?assert(RemoteStart >= WinStart + 2000).

standalone_values_are_verbatim() ->
    Group = {standalone_test, make_ref()},
    {ok, State} = seki_backend_pg:init(#{
        table_name => standalone_test, group => Group, gossip_interval => 3600000
    }),
    {ok, 42} = seki_backend_pg:update(State, k, fun(_) -> 42 end, 0),
    ok = pg:join(seki_pg, Group, self()),
    try
        gossip_pid(State) ! gossip,
        receive
            {'$gen_cast', {seki_gossip, 2, undefined, Entries}} ->
                ?assertEqual([{k, 42}], Entries)
        after 2000 -> ?assert(false)
        end
    after
        pg:leave(seki_pg, Group, self()),
        seki_backend_pg:terminate(State)
    end.

other_algorithm_is_ignored() ->
    {Gossip, State} = gossip_limiter(other_algorithm, gcra),
    gen_server:cast(Gossip, {seki_gossip, 2, token_bucket, [{k, {5.0, 0}}]}),
    {error, unknown} = gen_server:call(Gossip, sync),
    Result = seki_backend_pg:get(State, k),
    seki:delete_limiter(other_algorithm),
    ?assertEqual(not_found, Result).

capture_gossip(Name, Gossip, Algorithm) ->
    Group = {seki_limiters, list_to_atom("seki_limiter_" ++ atom_to_list(Name))},
    ok = pg:join(seki_pg, Group, self()),
    try
        Gossip ! gossip,
        receive
            {'$gen_cast', {seki_gossip, 2, Algorithm, Entries}} -> Entries
        after 2000 -> error(no_gossip)
        end
    after
        pg:leave(seki_pg, Group, self())
    end.

gossip_limiter(Name) ->
    gossip_limiter(Name, gcra).

gossip_limiter(Name, Algorithm) ->
    ok = seki:new_limiter(Name, #{
        algorithm => Algorithm,
        limit => 10,
        window => 1000,
        backend => seki_backend_pg,
        backend_opts => #{gossip_interval => 3600000}
    }),
    {Algorithm, seki_backend_pg, State, _} = seki_limiter_registry:lookup(Name),
    {gossip_pid(State), State}.

gossip_pid(State) when is_tuple(State) ->
    element(3, State).
