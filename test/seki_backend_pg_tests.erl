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
        {"gossip merge - GCRA", fun merge_gcra/0}
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
    ets:insert(Tab, {key1, 100}),
    {ok, Pid} = seki_pg_gossip:start_link(#{
        scope => seki_pg,
        group => gossip_test_group_2,
        tab => Tab,
        interval => 60000
    }),
    %% Send merge cast with higher GCRA TAT
    gen_server:cast(Pid, {merge, [{key1, 200}]}),
    timer:sleep(20),
    [{key1, TAT}] = ets:lookup(Tab, key1),
    ?assertEqual(200, TAT),
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
    %% Wait for Pid1 to gossip to Pid2
    timer:sleep(100),
    case ets:lookup(Tab2, key1) of
        [{key1, Val}] -> ?assertEqual(500, Val);
        [] -> ?assert(false)
    end,
    seki_pg_gossip:stop(Pid1),
    seki_pg_gossip:stop(Pid2),
    ets:delete(Tab1),
    ets:delete(Tab2).

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
