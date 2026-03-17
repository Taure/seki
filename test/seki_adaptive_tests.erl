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
        {"releases on process crash", fun aimd_crash_release/0}
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
    %% Many successful calls should increase the limit
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
    %% Errors should decrease the limit
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

gradient_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"gradient allows calls", fun gradient_allows/0},
        {"gradient adjusts on latency", fun gradient_adjusts/0},
        {"gradient reduces on drops", fun gradient_drops/0}
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
    %% Quick calls should gradually increase limit
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
    %% Drops should reduce limit
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
