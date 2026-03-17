-module(seki_limiter_tests).

-include_lib("eunit/include/eunit.hrl").

%%----------------------------------------------------------------------
%% Setup / Teardown
%%----------------------------------------------------------------------

setup() ->
    {ok, _} = application:ensure_all_started(seki),
    ok.

cleanup(_) ->
    application:stop(seki),
    ok.

%%----------------------------------------------------------------------
%% Token Bucket Tests
%%----------------------------------------------------------------------

token_bucket_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"allows requests within limit", fun token_bucket_allow/0},
        {"denies requests over limit", fun token_bucket_deny/0},
        {"inspect does not consume", fun token_bucket_inspect/0},
        {"remaining decreases with each request", fun token_bucket_remaining/0},
        {"reset is positive", fun token_bucket_reset/0},
        {"refills tokens over time", fun token_bucket_refill/0},
        {"inspect when depleted returns deny", fun token_bucket_inspect_depleted/0},
        {"burst defaults to limit", fun token_bucket_burst_default/0}
    ]}.

token_bucket_allow() ->
    ok = seki:new_limiter(tb_allow, #{
        algorithm => token_bucket,
        limit => 10,
        window => 1000
    }),
    {allow, #{remaining := R}} = seki:check(tb_allow, user1),
    ?assert(R >= 0),
    {allow, #{remaining := R2}} = seki:check(tb_allow, user1),
    ?assert(R2 >= 0),
    seki:delete_limiter(tb_allow).

token_bucket_deny() ->
    ok = seki:new_limiter(tb_deny, #{
        algorithm => token_bucket,
        limit => 3,
        window => 60000,
        burst => 3
    }),
    {allow, _} = seki:check(tb_deny, user1),
    {allow, _} = seki:check(tb_deny, user1),
    {allow, _} = seki:check(tb_deny, user1),
    {deny, #{retry_after := RetryAfter}} = seki:check(tb_deny, user1),
    ?assert(RetryAfter > 0),
    seki:delete_limiter(tb_deny).

token_bucket_inspect() ->
    ok = seki:new_limiter(tb_inspect, #{
        algorithm => token_bucket,
        limit => 5,
        window => 1000,
        burst => 5
    }),
    {allow, #{remaining := R1}} = seki:inspect(tb_inspect, user1),
    {allow, #{remaining := R2}} = seki:inspect(tb_inspect, user1),
    ?assertEqual(R1, R2),
    seki:delete_limiter(tb_inspect).

token_bucket_remaining() ->
    ok = seki:new_limiter(tb_rem, #{
        algorithm => token_bucket,
        limit => 5,
        window => 60000,
        burst => 5
    }),
    {allow, #{remaining := R1}} = seki:check(tb_rem, key1),
    ?assertEqual(4, R1),
    {allow, #{remaining := R2}} = seki:check(tb_rem, key1),
    ?assertEqual(3, R2),
    {allow, #{remaining := R3}} = seki:check(tb_rem, key1),
    ?assertEqual(2, R3),
    seki:delete_limiter(tb_rem).

token_bucket_reset() ->
    ok = seki:new_limiter(tb_rst, #{
        algorithm => token_bucket,
        limit => 10,
        window => 1000,
        burst => 10
    }),
    {allow, #{reset := Reset}} = seki:check(tb_rst, key1),
    ?assert(Reset >= 0),
    seki:delete_limiter(tb_rst).

token_bucket_refill() ->
    ok = seki:new_limiter(tb_refill, #{
        algorithm => token_bucket,
        limit => 10,
        window => 100,
        burst => 10
    }),
    %% Consume all tokens
    lists:foreach(fun(_) -> seki:check(tb_refill, key1) end, lists:seq(1, 10)),
    {deny, _} = seki:check(tb_refill, key1),
    %% Wait for refill
    timer:sleep(120),
    {allow, _} = seki:check(tb_refill, key1),
    seki:delete_limiter(tb_refill).

token_bucket_inspect_depleted() ->
    ok = seki:new_limiter(tb_insp_dep, #{
        algorithm => token_bucket,
        limit => 2,
        window => 60000,
        burst => 2
    }),
    {allow, _} = seki:check(tb_insp_dep, key1),
    {allow, _} = seki:check(tb_insp_dep, key1),
    {deny, #{retry_after := R}} = seki:inspect(tb_insp_dep, key1),
    ?assert(R > 0),
    seki:delete_limiter(tb_insp_dep).

token_bucket_burst_default() ->
    ok = seki:new_limiter(tb_burst_def, #{
        algorithm => token_bucket,
        limit => 7,
        window => 60000
    }),
    %% Burst defaults to limit, so 7 requests should be allowed
    lists:foreach(
        fun(_) ->
            {allow, _} = seki:check(tb_burst_def, key1)
        end,
        lists:seq(1, 7)
    ),
    {deny, _} = seki:check(tb_burst_def, key1),
    seki:delete_limiter(tb_burst_def).

%%----------------------------------------------------------------------
%% Sliding Window Tests
%%----------------------------------------------------------------------

sliding_window_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"allows requests within limit", fun sliding_window_allow/0},
        {"denies requests over limit", fun sliding_window_deny/0},
        {"different keys are independent", fun sliding_window_keys/0},
        {"remaining decreases correctly", fun sliding_window_remaining/0},
        {"retry_after is positive on deny", fun sliding_window_retry_after/0},
        {"inspect does not consume", fun sliding_window_inspect/0},
        {"inspect shows deny when over limit", fun sliding_window_inspect_deny/0},
        {"window rolls over", fun sliding_window_rollover/0}
    ]}.

sliding_window_allow() ->
    ok = seki:new_limiter(sw_allow, #{
        algorithm => sliding_window,
        limit => 10,
        window => 1000
    }),
    {allow, #{remaining := R}} = seki:check(sw_allow, user1),
    ?assert(R >= 0),
    ?assert(R =< 10),
    seki:delete_limiter(sw_allow).

sliding_window_deny() ->
    ok = seki:new_limiter(sw_deny, #{
        algorithm => sliding_window,
        limit => 3,
        window => 60000
    }),
    {allow, _} = seki:check(sw_deny, user1),
    {allow, _} = seki:check(sw_deny, user1),
    {allow, _} = seki:check(sw_deny, user1),
    {deny, #{retry_after := _}} = seki:check(sw_deny, user1),
    seki:delete_limiter(sw_deny).

sliding_window_keys() ->
    ok = seki:new_limiter(sw_keys, #{
        algorithm => sliding_window,
        limit => 2,
        window => 60000
    }),
    {allow, _} = seki:check(sw_keys, user1),
    {allow, _} = seki:check(sw_keys, user1),
    {deny, _} = seki:check(sw_keys, user1),
    %% Different key should still be allowed
    {allow, _} = seki:check(sw_keys, user2),
    seki:delete_limiter(sw_keys).

sliding_window_remaining() ->
    ok = seki:new_limiter(sw_rem, #{
        algorithm => sliding_window,
        limit => 5,
        window => 60000
    }),
    {allow, #{remaining := R1}} = seki:check(sw_rem, key1),
    ?assertEqual(4, R1),
    {allow, #{remaining := R2}} = seki:check(sw_rem, key1),
    ?assertEqual(3, R2),
    seki:delete_limiter(sw_rem).

sliding_window_retry_after() ->
    ok = seki:new_limiter(sw_ra, #{
        algorithm => sliding_window,
        limit => 1,
        window => 60000
    }),
    {allow, _} = seki:check(sw_ra, key1),
    {deny, #{retry_after := RetryAfter}} = seki:check(sw_ra, key1),
    ?assert(RetryAfter > 0),
    seki:delete_limiter(sw_ra).

sliding_window_inspect() ->
    ok = seki:new_limiter(sw_insp, #{
        algorithm => sliding_window,
        limit => 5,
        window => 60000
    }),
    %% Inspect before any checks — should have full remaining
    {allow, #{remaining := R1}} = seki:inspect(sw_insp, key1),
    ?assertEqual(5, R1),
    %% Consume one
    {allow, _} = seki:check(sw_insp, key1),
    %% Inspect should see reduced remaining
    {allow, #{remaining := R2}} = seki:inspect(sw_insp, key1),
    ?assert(R2 < R1),
    seki:delete_limiter(sw_insp).

sliding_window_inspect_deny() ->
    ok = seki:new_limiter(sw_insp_d, #{
        algorithm => sliding_window,
        limit => 1,
        window => 60000
    }),
    {allow, _} = seki:check(sw_insp_d, key1),
    {deny, #{retry_after := R}} = seki:inspect(sw_insp_d, key1),
    ?assert(R > 0),
    seki:delete_limiter(sw_insp_d).

sliding_window_rollover() ->
    ok = seki:new_limiter(sw_roll, #{
        algorithm => sliding_window,
        limit => 2,
        window => 50
    }),
    {allow, _} = seki:check(sw_roll, key1),
    {allow, _} = seki:check(sw_roll, key1),
    {deny, _} = seki:check(sw_roll, key1),
    %% Wait for two full windows to pass (prev window must expire too)
    timer:sleep(200),
    {allow, _} = seki:check(sw_roll, key1),
    seki:delete_limiter(sw_roll).

%%----------------------------------------------------------------------
%% GCRA Tests
%%----------------------------------------------------------------------

gcra_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"allows requests within limit", fun gcra_allow/0},
        {"denies requests over limit", fun gcra_deny/0},
        {"reset clears state", fun gcra_reset/0},
        {"remaining decreases", fun gcra_remaining/0},
        {"inspect does not consume", fun gcra_inspect/0},
        {"inspect shows deny when over", fun gcra_inspect_deny/0},
        {"recovers after time", fun gcra_recovery/0}
    ]}.

gcra_allow() ->
    ok = seki:new_limiter(gcra_allow, #{
        algorithm => gcra,
        limit => 10,
        window => 1000
    }),
    {allow, #{remaining := R}} = seki:check(gcra_allow, user1),
    ?assert(R >= 0),
    seki:delete_limiter(gcra_allow).

gcra_deny() ->
    ok = seki:new_limiter(gcra_deny, #{
        algorithm => gcra,
        limit => 3,
        window => 60000
    }),
    {allow, _} = seki:check(gcra_deny, user1),
    {allow, _} = seki:check(gcra_deny, user1),
    {allow, _} = seki:check(gcra_deny, user1),
    {deny, #{retry_after := RetryAfter}} = seki:check(gcra_deny, user1),
    ?assert(RetryAfter > 0),
    seki:delete_limiter(gcra_deny).

gcra_reset() ->
    ok = seki:new_limiter(gcra_reset, #{
        algorithm => gcra,
        limit => 2,
        window => 60000
    }),
    {allow, _} = seki:check(gcra_reset, user1),
    {allow, _} = seki:check(gcra_reset, user1),
    {deny, _} = seki:check(gcra_reset, user1),
    seki:reset(gcra_reset, user1),
    {allow, _} = seki:check(gcra_reset, user1),
    seki:delete_limiter(gcra_reset).

gcra_remaining() ->
    ok = seki:new_limiter(gcra_rem, #{
        algorithm => gcra,
        limit => 5,
        window => 60000
    }),
    {allow, #{remaining := R1}} = seki:check(gcra_rem, key1),
    ?assertEqual(4, R1),
    {allow, #{remaining := R2}} = seki:check(gcra_rem, key1),
    ?assert(R2 < R1),
    seki:delete_limiter(gcra_rem).

gcra_inspect() ->
    ok = seki:new_limiter(gcra_insp, #{
        algorithm => gcra,
        limit => 5,
        window => 60000
    }),
    {allow, #{remaining := R1}} = seki:inspect(gcra_insp, key1),
    ?assertEqual(5, R1),
    {allow, #{remaining := R2}} = seki:inspect(gcra_insp, key1),
    ?assertEqual(R1, R2),
    seki:delete_limiter(gcra_insp).

gcra_inspect_deny() ->
    ok = seki:new_limiter(gcra_insp_d, #{
        algorithm => gcra,
        limit => 2,
        window => 60000
    }),
    {allow, _} = seki:check(gcra_insp_d, key1),
    {allow, _} = seki:check(gcra_insp_d, key1),
    {deny, #{retry_after := R}} = seki:inspect(gcra_insp_d, key1),
    ?assert(R > 0),
    seki:delete_limiter(gcra_insp_d).

gcra_recovery() ->
    ok = seki:new_limiter(gcra_rec, #{
        algorithm => gcra,
        limit => 2,
        window => 100
    }),
    {allow, _} = seki:check(gcra_rec, key1),
    {allow, _} = seki:check(gcra_rec, key1),
    {deny, _} = seki:check(gcra_rec, key1),
    timer:sleep(120),
    {allow, _} = seki:check(gcra_rec, key1),
    seki:delete_limiter(gcra_rec).

%%----------------------------------------------------------------------
%% Leaky Bucket Tests
%%----------------------------------------------------------------------

leaky_bucket_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"allows requests within limit", fun leaky_bucket_allow/0},
        {"denies requests over limit", fun leaky_bucket_deny/0},
        {"remaining decreases", fun leaky_bucket_remaining/0},
        {"drains over time", fun leaky_bucket_drain/0},
        {"inspect does not consume", fun leaky_bucket_inspect/0},
        {"inspect shows deny when full", fun leaky_bucket_inspect_deny/0},
        {"reset is positive", fun leaky_bucket_reset_value/0}
    ]}.

leaky_bucket_allow() ->
    ok = seki:new_limiter(lb_allow, #{
        algorithm => leaky_bucket,
        limit => 10,
        window => 1000
    }),
    {allow, #{remaining := R}} = seki:check(lb_allow, user1),
    ?assert(R >= 0),
    seki:delete_limiter(lb_allow).

leaky_bucket_deny() ->
    ok = seki:new_limiter(lb_deny, #{
        algorithm => leaky_bucket,
        limit => 3,
        window => 60000
    }),
    {allow, _} = seki:check(lb_deny, user1),
    {allow, _} = seki:check(lb_deny, user1),
    {allow, _} = seki:check(lb_deny, user1),
    {deny, #{retry_after := R}} = seki:check(lb_deny, user1),
    ?assert(R > 0),
    seki:delete_limiter(lb_deny).

leaky_bucket_remaining() ->
    ok = seki:new_limiter(lb_rem, #{
        algorithm => leaky_bucket,
        limit => 5,
        window => 60000
    }),
    {allow, #{remaining := R1}} = seki:check(lb_rem, key1),
    ?assertEqual(4, R1),
    {allow, #{remaining := R2}} = seki:check(lb_rem, key1),
    ?assertEqual(3, R2),
    seki:delete_limiter(lb_rem).

leaky_bucket_drain() ->
    ok = seki:new_limiter(lb_drain, #{
        algorithm => leaky_bucket,
        limit => 5,
        window => 100
    }),
    %% Fill the bucket
    lists:foreach(fun(_) -> seki:check(lb_drain, key1) end, lists:seq(1, 5)),
    {deny, _} = seki:check(lb_drain, key1),
    %% Wait for drain
    timer:sleep(120),
    {allow, _} = seki:check(lb_drain, key1),
    seki:delete_limiter(lb_drain).

leaky_bucket_inspect() ->
    ok = seki:new_limiter(lb_insp, #{
        algorithm => leaky_bucket,
        limit => 5,
        window => 60000
    }),
    {allow, #{remaining := R1}} = seki:inspect(lb_insp, key1),
    ?assertEqual(5, R1),
    {allow, #{remaining := R2}} = seki:inspect(lb_insp, key1),
    ?assertEqual(R1, R2),
    seki:delete_limiter(lb_insp).

leaky_bucket_inspect_deny() ->
    ok = seki:new_limiter(lb_insp_d, #{
        algorithm => leaky_bucket,
        limit => 2,
        window => 60000
    }),
    {allow, _} = seki:check(lb_insp_d, key1),
    {allow, _} = seki:check(lb_insp_d, key1),
    {deny, #{retry_after := R}} = seki:inspect(lb_insp_d, key1),
    ?assert(R > 0),
    seki:delete_limiter(lb_insp_d).

leaky_bucket_reset_value() ->
    ok = seki:new_limiter(lb_rst, #{
        algorithm => leaky_bucket,
        limit => 10,
        window => 1000
    }),
    {allow, #{reset := Reset}} = seki:check(lb_rst, key1),
    ?assert(Reset >= 0),
    seki:delete_limiter(lb_rst).

%%----------------------------------------------------------------------
%% Cost Tests
%%----------------------------------------------------------------------

cost_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"weighted cost consumes more", fun cost_weighted/0},
        {"cost with sliding window", fun cost_sliding_window/0},
        {"cost with gcra", fun cost_gcra/0},
        {"cost with leaky bucket", fun cost_leaky_bucket/0},
        {"inspect with cost", fun cost_inspect/0}
    ]}.

cost_weighted() ->
    ok = seki:new_limiter(cost_w, #{
        algorithm => token_bucket,
        limit => 10,
        window => 60000,
        burst => 10
    }),
    %% Cost of 5 should consume 5 tokens
    {allow, #{remaining := R1}} = seki:check(cost_w, user1, 5),
    ?assertEqual(5, R1),
    {allow, #{remaining := R2}} = seki:check(cost_w, user1, 5),
    ?assertEqual(0, R2),
    {deny, _} = seki:check(cost_w, user1, 1),
    seki:delete_limiter(cost_w).

cost_sliding_window() ->
    ok = seki:new_limiter(cost_sw, #{
        algorithm => sliding_window,
        limit => 10,
        window => 60000
    }),
    {allow, _} = seki:check(cost_sw, key1, 5),
    {allow, _} = seki:check(cost_sw, key1, 5),
    {deny, _} = seki:check(cost_sw, key1, 1),
    seki:delete_limiter(cost_sw).

cost_gcra() ->
    ok = seki:new_limiter(cost_gcra, #{
        algorithm => gcra,
        limit => 10,
        window => 60000
    }),
    {allow, _} = seki:check(cost_gcra, key1, 5),
    {allow, _} = seki:check(cost_gcra, key1, 5),
    {deny, _} = seki:check(cost_gcra, key1, 1),
    seki:delete_limiter(cost_gcra).

cost_leaky_bucket() ->
    ok = seki:new_limiter(cost_lb, #{
        algorithm => leaky_bucket,
        limit => 10,
        window => 60000
    }),
    {allow, _} = seki:check(cost_lb, key1, 5),
    {allow, _} = seki:check(cost_lb, key1, 5),
    {deny, _} = seki:check(cost_lb, key1, 1),
    seki:delete_limiter(cost_lb).

cost_inspect() ->
    ok = seki:new_limiter(cost_insp, #{
        algorithm => token_bucket,
        limit => 10,
        window => 60000,
        burst => 10
    }),
    {allow, _} = seki:check(cost_insp, key1, 8),
    %% Inspect with cost 3 should show deny (only 2 remaining)
    {deny, _} = seki:inspect(cost_insp, key1, 3),
    %% Inspect with cost 1 should still allow
    {allow, _} = seki:inspect(cost_insp, key1, 1),
    seki:delete_limiter(cost_insp).

%%----------------------------------------------------------------------
%% Execute (Combined) Tests
%%----------------------------------------------------------------------

execute_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"execute succeeds", fun execute_success/0},
        {"execute rate limited", fun execute_rate_limited/0},
        {"execute circuit open", fun execute_circuit_open/0}
    ]}.

execute_success() ->
    ok = seki:new_limiter(exec_lim, #{
        algorithm => token_bucket,
        limit => 10,
        window => 60000
    }),
    {ok, _} = seki:new_breaker(exec_brk, #{window_size => 5}),
    {ok, hello} = seki:execute(exec_brk, exec_lim, fun() -> hello end),
    seki:delete_breaker(exec_brk),
    seki:delete_limiter(exec_lim).

execute_rate_limited() ->
    ok = seki:new_limiter(exec_lim2, #{
        algorithm => token_bucket,
        limit => 1,
        window => 60000,
        burst => 1
    }),
    {ok, _} = seki:new_breaker(exec_brk2, #{window_size => 5}),
    {ok, _} = seki:execute(exec_brk2, exec_lim2, fun() -> ok end),
    {error, {rate_limited, #{retry_after := _}}} =
        seki:execute(exec_brk2, exec_lim2, fun() -> ok end),
    seki:delete_breaker(exec_brk2),
    seki:delete_limiter(exec_lim2).

execute_circuit_open() ->
    ok = seki:new_limiter(exec_lim3, #{
        algorithm => token_bucket,
        limit => 100,
        window => 60000
    }),
    {ok, _} = seki:new_breaker(exec_brk3, #{
        window_size => 5,
        failure_threshold => 50,
        wait_duration => 60000
    }),
    %% Trip the breaker
    lists:foreach(
        fun(_) -> seki:call(exec_brk3, fun() -> {error, boom} end) end,
        lists:seq(1, 5)
    ),
    {error, circuit_open} = seki:execute(exec_brk3, exec_lim3, fun() -> ok end),
    seki:delete_breaker(exec_brk3),
    seki:delete_limiter(exec_lim3).

%%----------------------------------------------------------------------
%% Registry Tests
%%----------------------------------------------------------------------

registry_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"double register fails", fun double_register/0},
        {"lookup not found raises", fun lookup_not_found/0},
        {"unregister nonexistent is ok", fun unregister_nonexistent/0},
        {"delete then re-register works", fun re_register/0}
    ]}.

double_register() ->
    ok = seki:new_limiter(reg_dup, #{
        algorithm => token_bucket,
        limit => 10,
        window => 1000
    }),
    {error, already_registered} = seki:new_limiter(reg_dup, #{
        algorithm => token_bucket,
        limit => 10,
        window => 1000
    }),
    seki:delete_limiter(reg_dup).

lookup_not_found() ->
    ?assertError(
        {limiter_not_found, nonexistent_limiter_xyz},
        seki:check(nonexistent_limiter_xyz, key1)
    ).

unregister_nonexistent() ->
    ok = seki:delete_limiter(never_existed_limiter).

re_register() ->
    ok = seki:new_limiter(reg_re, #{
        algorithm => token_bucket,
        limit => 5,
        window => 60000,
        burst => 5
    }),
    {allow, _} = seki:check(reg_re, key1),
    ok = seki:delete_limiter(reg_re),
    ok = seki:new_limiter(reg_re, #{
        algorithm => sliding_window,
        limit => 5,
        window => 60000
    }),
    {allow, _} = seki:check(reg_re, key1),
    seki:delete_limiter(reg_re).
