-module(seki_adaptive_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(seki),
    ok.

cleanup(_) ->
    application:stop(seki),
    ok.

aimd_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"starts with initial limit", fun aimd_initial/0},
        {"allows calls within limit", fun aimd_allows/0},
        {"rejects when limit reached", fun aimd_rejects/0},
        {"increases limit on success", fun aimd_increases/0},
        {"decreases limit on errors", fun aimd_decreases/0},
        {"call wraps acquire/release", fun aimd_call/0},
        {"call reports error on exception", fun aimd_call_exception/0},
        {"call rejects when full", fun aimd_call_rejects/0},
        {"call/3 accepts options", fun aimd_call_3/0},
        {"releases on process crash", fun aimd_crash_release/0},
        {"min_limit is respected", fun aimd_min_limit/0},
        {"max_limit is respected", fun aimd_max_limit/0},
        {"timeout outcome decreases", fun aimd_timeout/0},
        {"status shows available correctly", fun aimd_status_available/0}
    ]}.

aimd_initial() ->
    {ok, _} = seki_adaptive:start_link(ad_init, #{
        algorithm => aimd,
        initial_limit => 10
    }),
    #{current_limit := 10, in_flight := 0, available := 10} = seki_adaptive:status(ad_init),
    gen_server:stop(ad_init).

aimd_allows() ->
    {ok, _} = seki_adaptive:start_link(ad_allow, #{
        algorithm => aimd,
        initial_limit => 5
    }),
    ok = seki_adaptive:acquire(ad_allow),
    ok = seki_adaptive:acquire(ad_allow),
    #{in_flight := 2} = seki_adaptive:status(ad_allow),
    seki_adaptive:release(ad_allow, ok),
    seki_adaptive:release(ad_allow, ok),
    timer:sleep(10),
    #{in_flight := 0} = seki_adaptive:status(ad_allow),
    gen_server:stop(ad_allow).

aimd_rejects() ->
    {ok, _} = seki_adaptive:start_link(ad_reject, #{
        algorithm => aimd,
        initial_limit => 2
    }),
    ok = seki_adaptive:acquire(ad_reject),
    ok = seki_adaptive:acquire(ad_reject),
    ?assertEqual({error, limit_reached}, seki_adaptive:acquire(ad_reject)),
    seki_adaptive:release(ad_reject, ok),
    seki_adaptive:release(ad_reject, ok),
    gen_server:stop(ad_reject).

aimd_increases() ->
    {ok, _} = seki_adaptive:start_link(ad_inc, #{
        algorithm => aimd,
        initial_limit => 5
    }),
    lists:foreach(
        fun(_) ->
            ok = seki_adaptive:acquire(ad_inc),
            seki_adaptive:release(ad_inc, ok)
        end,
        lists:seq(1, 50)
    ),
    timer:sleep(10),
    #{current_limit := Limit} = seki_adaptive:status(ad_inc),
    ?assert(Limit > 5),
    gen_server:stop(ad_inc).

aimd_decreases() ->
    {ok, _} = seki_adaptive:start_link(ad_dec, #{
        algorithm => aimd,
        initial_limit => 20,
        backoff_ratio => 0.5
    }),
    lists:foreach(
        fun(_) ->
            ok = seki_adaptive:acquire(ad_dec),
            seki_adaptive:release(ad_dec, error)
        end,
        lists:seq(1, 10)
    ),
    timer:sleep(10),
    #{current_limit := Limit} = seki_adaptive:status(ad_dec),
    ?assert(Limit < 20),
    gen_server:stop(ad_dec).

aimd_call() ->
    {ok, _} = seki_adaptive:start_link(ad_call, #{
        algorithm => aimd,
        initial_limit => 5
    }),
    ?assertEqual({ok, 42}, seki_adaptive:call(ad_call, fun() -> 42 end)),
    #{in_flight := 0} = seki_adaptive:status(ad_call),
    gen_server:stop(ad_call).

aimd_call_exception() ->
    {ok, _} = seki_adaptive:start_link(ad_call_exc, #{
        algorithm => aimd,
        initial_limit => 5
    }),
    {error, {error, boom, _}} = seki_adaptive:call(ad_call_exc, fun() -> error(boom) end),
    timer:sleep(10),
    #{in_flight := 0} = seki_adaptive:status(ad_call_exc),
    gen_server:stop(ad_call_exc).

aimd_call_rejects() ->
    {ok, _} = seki_adaptive:start_link(ad_call_rej, #{
        algorithm => aimd,
        initial_limit => 1
    }),
    Self = self(),
    spawn(fun() ->
        ok = seki_adaptive:acquire(ad_call_rej),
        Self ! acquired,
        receive
            stop -> ok
        end,
        seki_adaptive:release(ad_call_rej, ok)
    end),
    receive
        acquired -> ok
    end,
    ?assertEqual({error, limit_reached}, seki_adaptive:call(ad_call_rej, fun() -> ok end)),
    gen_server:stop(ad_call_rej).

aimd_call_3() ->
    {ok, _} = seki_adaptive:start_link(ad_call3, #{
        algorithm => aimd,
        initial_limit => 5
    }),
    ?assertEqual({ok, opts_ok}, seki_adaptive:call(ad_call3, fun() -> opts_ok end, #{})),
    gen_server:stop(ad_call3).

aimd_crash_release() ->
    {ok, _} = seki_adaptive:start_link(ad_crash, #{
        algorithm => aimd,
        initial_limit => 2
    }),
    Self = self(),
    Pid = spawn(fun() ->
        ok = seki_adaptive:acquire(ad_crash),
        Self ! acquired,
        receive
            stop -> ok
        end
    end),
    receive
        acquired -> ok
    end,
    #{in_flight := 1} = seki_adaptive:status(ad_crash),
    exit(Pid, kill),
    timer:sleep(50),
    #{in_flight := 0} = seki_adaptive:status(ad_crash),
    gen_server:stop(ad_crash).

aimd_min_limit() ->
    {ok, _} = seki_adaptive:start_link(ad_min, #{
        algorithm => aimd,
        initial_limit => 3,
        min_limit => 2,
        backoff_ratio => 0.1
    }),
    %% Many errors should reduce but not below min_limit
    lists:foreach(
        fun(_) ->
            ok = seki_adaptive:acquire(ad_min),
            seki_adaptive:release(ad_min, error)
        end,
        lists:seq(1, 50)
    ),
    timer:sleep(10),
    #{current_limit := Limit} = seki_adaptive:status(ad_min),
    ?assert(Limit >= 2),
    gen_server:stop(ad_min).

aimd_max_limit() ->
    {ok, _} = seki_adaptive:start_link(ad_max, #{
        algorithm => aimd,
        initial_limit => 5,
        max_limit => 8
    }),
    lists:foreach(
        fun(_) ->
            ok = seki_adaptive:acquire(ad_max),
            seki_adaptive:release(ad_max, ok)
        end,
        lists:seq(1, 200)
    ),
    timer:sleep(10),
    #{current_limit := Limit} = seki_adaptive:status(ad_max),
    ?assert(Limit =< 8),
    gen_server:stop(ad_max).

aimd_timeout() ->
    {ok, _} = seki_adaptive:start_link(ad_timeout, #{
        algorithm => aimd,
        initial_limit => 10,
        backoff_ratio => 0.5
    }),
    lists:foreach(
        fun(_) ->
            ok = seki_adaptive:acquire(ad_timeout),
            seki_adaptive:release(ad_timeout, timeout)
        end,
        lists:seq(1, 10)
    ),
    timer:sleep(10),
    #{current_limit := Limit} = seki_adaptive:status(ad_timeout),
    ?assert(Limit < 10),
    gen_server:stop(ad_timeout).

aimd_status_available() ->
    {ok, _} = seki_adaptive:start_link(ad_avail, #{
        algorithm => aimd,
        initial_limit => 5
    }),
    #{available := 5} = seki_adaptive:status(ad_avail),
    ok = seki_adaptive:acquire(ad_avail),
    #{available := 4, in_flight := 1} = seki_adaptive:status(ad_avail),
    seki_adaptive:release(ad_avail, ok),
    timer:sleep(10),
    #{available := A} = seki_adaptive:status(ad_avail),
    ?assert(A >= 5),
    gen_server:stop(ad_avail).

%%----------------------------------------------------------------------
%% Gradient Tests
%%----------------------------------------------------------------------

gradient_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"gradient allows calls", fun gradient_allows/0},
        {"gradient adjusts on latency", fun gradient_adjusts/0},
        {"gradient reduces on drops", fun gradient_drops/0},
        {"gradient timeout treated as drop", fun gradient_timeout/0},
        {"gradient error does not change limit", fun gradient_error_stable/0},
        {"gradient call wraps correctly", fun gradient_call/0},
        {"gradient with high tolerance stays stable", fun gradient_high_tolerance/0}
    ]}.

gradient_allows() ->
    {ok, _} = seki_adaptive:start_link(gr_allow, #{
        algorithm => gradient,
        initial_limit => 10
    }),
    ?assertEqual({ok, hello}, seki_adaptive:call(gr_allow, fun() -> hello end)),
    gen_server:stop(gr_allow).

gradient_adjusts() ->
    {ok, _} = seki_adaptive:start_link(gr_adj, #{
        algorithm => gradient,
        initial_limit => 10,
        smoothing => 0.5
    }),
    lists:foreach(
        fun(_) ->
            ok = seki_adaptive:acquire(gr_adj),
            seki_adaptive:release(gr_adj, ok)
        end,
        lists:seq(1, 30)
    ),
    timer:sleep(10),
    #{current_limit := Limit} = seki_adaptive:status(gr_adj),
    ?assert(Limit >= 10),
    gen_server:stop(gr_adj).

gradient_drops() ->
    {ok, _} = seki_adaptive:start_link(gr_drop, #{
        algorithm => gradient,
        initial_limit => 20
    }),
    lists:foreach(
        fun(_) ->
            ok = seki_adaptive:acquire(gr_drop),
            seki_adaptive:release(gr_drop, drop)
        end,
        lists:seq(1, 10)
    ),
    timer:sleep(10),
    #{current_limit := Limit} = seki_adaptive:status(gr_drop),
    ?assert(Limit < 20),
    gen_server:stop(gr_drop).

gradient_timeout() ->
    {ok, _} = seki_adaptive:start_link(gr_to, #{
        algorithm => gradient,
        initial_limit => 20
    }),
    lists:foreach(
        fun(_) ->
            ok = seki_adaptive:acquire(gr_to),
            seki_adaptive:release(gr_to, timeout)
        end,
        lists:seq(1, 10)
    ),
    timer:sleep(10),
    #{current_limit := Limit} = seki_adaptive:status(gr_to),
    ?assert(Limit < 20),
    gen_server:stop(gr_to).

gradient_error_stable() ->
    {ok, _} = seki_adaptive:start_link(gr_err, #{
        algorithm => gradient,
        initial_limit => 10
    }),
    #{current_limit := Before} = seki_adaptive:status(gr_err),
    lists:foreach(
        fun(_) ->
            ok = seki_adaptive:acquire(gr_err),
            seki_adaptive:release(gr_err, error)
        end,
        lists:seq(1, 5)
    ),
    timer:sleep(10),
    #{current_limit := After} = seki_adaptive:status(gr_err),
    %% Errors should not change limit in gradient mode
    ?assertEqual(Before, After),
    gen_server:stop(gr_err).

gradient_call() ->
    {ok, _} = seki_adaptive:start_link(gr_call, #{
        algorithm => gradient,
        initial_limit => 5
    }),
    {ok, result} = seki_adaptive:call(gr_call, fun() -> result end),
    #{in_flight := 0} = seki_adaptive:status(gr_call),
    gen_server:stop(gr_call).

gradient_high_tolerance() ->
    {ok, _} = seki_adaptive:start_link(gr_tol, #{
        algorithm => gradient,
        initial_limit => 10,
        tolerance => 5.0,
        smoothing => 0.9
    }),
    lists:foreach(
        fun(_) ->
            ok = seki_adaptive:acquire(gr_tol),
            timer:sleep(1),
            seki_adaptive:release(gr_tol, ok)
        end,
        lists:seq(1, 20)
    ),
    timer:sleep(10),
    #{current_limit := Limit} = seki_adaptive:status(gr_tol),
    %% With high tolerance, limit should increase
    ?assert(Limit >= 10),
    gen_server:stop(gr_tol).
