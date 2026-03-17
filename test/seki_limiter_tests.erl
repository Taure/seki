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
        {"inspect does not consume", fun token_bucket_inspect/0}
    ]}.

token_bucket_allow() ->
    ok = seki:new_limiter(tb_allow, #{
        algorithm => token_bucket,
        limit => 10,
        window => 1000
    }),
    {allow, #{remaining := _}} = seki:check(tb_allow, user1),
    {allow, #{remaining := _}} = seki:check(tb_allow, user1),
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

%%----------------------------------------------------------------------
%% Sliding Window Tests
%%----------------------------------------------------------------------

sliding_window_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"allows requests within limit", fun sliding_window_allow/0},
        {"denies requests over limit", fun sliding_window_deny/0},
        {"different keys are independent", fun sliding_window_keys/0}
    ]}.

sliding_window_allow() ->
    ok = seki:new_limiter(sw_allow, #{
        algorithm => sliding_window,
        limit => 10,
        window => 1000
    }),
    {allow, #{remaining := _}} = seki:check(sw_allow, user1),
    {allow, #{remaining := _}} = seki:check(sw_allow, user1),
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

%%----------------------------------------------------------------------
%% GCRA Tests
%%----------------------------------------------------------------------

gcra_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"allows requests within limit", fun gcra_allow/0},
        {"denies requests over limit", fun gcra_deny/0},
        {"reset clears state", fun gcra_reset/0}
    ]}.

gcra_allow() ->
    ok = seki:new_limiter(gcra_allow, #{
        algorithm => gcra,
        limit => 10,
        window => 1000
    }),
    {allow, #{remaining := _}} = seki:check(gcra_allow, user1),
    {allow, #{remaining := _}} = seki:check(gcra_allow, user1),
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

%%----------------------------------------------------------------------
%% Leaky Bucket Tests
%%----------------------------------------------------------------------

leaky_bucket_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"allows requests within limit", fun leaky_bucket_allow/0},
        {"denies requests over limit", fun leaky_bucket_deny/0}
    ]}.

leaky_bucket_allow() ->
    ok = seki:new_limiter(lb_allow, #{
        algorithm => leaky_bucket,
        limit => 10,
        window => 1000
    }),
    {allow, #{remaining := _}} = seki:check(lb_allow, user1),
    {allow, #{remaining := _}} = seki:check(lb_allow, user1),
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
    {deny, #{retry_after := _}} = seki:check(lb_deny, user1),
    seki:delete_limiter(lb_deny).

%%----------------------------------------------------------------------
%% Cost Tests
%%----------------------------------------------------------------------

cost_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"weighted cost consumes more", fun cost_weighted/0}
    ]}.

cost_weighted() ->
    ok = seki:new_limiter(cost_w, #{
        algorithm => token_bucket,
        limit => 10,
        window => 60000,
        burst => 10
    }),
    %% Cost of 5 should consume 5 tokens
    {allow, _} = seki:check(cost_w, user1, 5),
    {allow, _} = seki:check(cost_w, user1, 5),
    {deny, _} = seki:check(cost_w, user1, 1),
    seki:delete_limiter(cost_w).
