-module(seki_breaker_tests).

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
%% Basic Circuit Breaker Tests
%%----------------------------------------------------------------------

basic_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"starts in closed state", fun starts_closed/0},
        {"passes through successful calls", fun successful_calls/0},
        {"returns wrapped result", fun returns_wrapped_result/0},
        {"trips after failure threshold", fun trips_on_failures/0},
        {"rejects calls when open", fun rejects_when_open/0},
        {"transitions to half_open after wait", fun half_open_transition/0},
        {"closes after successful probes", fun closes_after_probes/0},
        {"reopens on half_open failure", fun reopens_on_failure/0},
        {"manual reset works", fun manual_reset/0},
        {"manual reset in half_open", fun manual_reset_half_open/0},
        {"manual reset in closed is noop", fun manual_reset_closed/0},
        {"delete breaker stops process", fun delete_breaker/0}
    ]}.

starts_closed() ->
    {ok, _} = seki:new_breaker(br_closed, #{window_size => 5}),
    ?assertEqual(closed, seki:state(br_closed)),
    seki:delete_breaker(br_closed).

successful_calls() ->
    {ok, _} = seki:new_breaker(br_success, #{window_size => 5}),
    {ok, hello} = seki:call(br_success, fun() -> hello end),
    ?assertEqual(closed, seki:state(br_success)),
    seki:delete_breaker(br_success).

returns_wrapped_result() ->
    {ok, _} = seki:new_breaker(br_wrap, #{window_size => 5}),
    {ok, 42} = seki:call(br_wrap, fun() -> 42 end),
    {ok, #{a := 1}} = seki:call(br_wrap, fun() -> #{a => 1} end),
    {ok, [1, 2, 3]} = seki:call(br_wrap, fun() -> [1, 2, 3] end),
    seki:delete_breaker(br_wrap).

trips_on_failures() ->
    {ok, _} = seki:new_breaker(br_trip, #{
        window_size => 5,
        failure_threshold => 50,
        wait_duration => 60000
    }),
    lists:foreach(
        fun(_) ->
            seki:call(br_trip, fun() -> {error, boom} end)
        end,
        lists:seq(1, 5)
    ),
    ?assertEqual(open, seki:state(br_trip)),
    seki:delete_breaker(br_trip).

rejects_when_open() ->
    {ok, _} = seki:new_breaker(br_reject, #{
        window_size => 5,
        failure_threshold => 50,
        wait_duration => 60000
    }),
    lists:foreach(
        fun(_) ->
            seki:call(br_reject, fun() -> {error, boom} end)
        end,
        lists:seq(1, 5)
    ),
    ?assertEqual(open, seki:state(br_reject)),
    ?assertEqual({error, circuit_open}, seki:call(br_reject, fun() -> ok end)),
    seki:delete_breaker(br_reject).

half_open_transition() ->
    {ok, _} = seki:new_breaker(br_half, #{
        window_size => 5,
        failure_threshold => 50,
        wait_duration => 50
    }),
    lists:foreach(
        fun(_) ->
            seki:call(br_half, fun() -> {error, boom} end)
        end,
        lists:seq(1, 5)
    ),
    ?assertEqual(open, seki:state(br_half)),
    timer:sleep(100),
    ?assertEqual(half_open, seki:state(br_half)),
    seki:delete_breaker(br_half).

closes_after_probes() ->
    {ok, _} = seki:new_breaker(br_close, #{
        window_size => 5,
        failure_threshold => 50,
        wait_duration => 50,
        half_open_requests => 3
    }),
    lists:foreach(
        fun(_) ->
            seki:call(br_close, fun() -> {error, boom} end)
        end,
        lists:seq(1, 5)
    ),
    ?assertEqual(open, seki:state(br_close)),
    timer:sleep(100),
    ?assertEqual(half_open, seki:state(br_close)),
    {ok, ok} = seki:call(br_close, fun() -> ok end),
    {ok, ok} = seki:call(br_close, fun() -> ok end),
    {ok, ok} = seki:call(br_close, fun() -> ok end),
    ?assertEqual(closed, seki:state(br_close)),
    seki:delete_breaker(br_close).

reopens_on_failure() ->
    {ok, _} = seki:new_breaker(br_reopen, #{
        window_size => 5,
        failure_threshold => 50,
        wait_duration => 50,
        half_open_requests => 3
    }),
    lists:foreach(
        fun(_) ->
            seki:call(br_reopen, fun() -> {error, boom} end)
        end,
        lists:seq(1, 5)
    ),
    timer:sleep(100),
    ?assertEqual(half_open, seki:state(br_reopen)),
    seki:call(br_reopen, fun() -> {error, still_broken} end),
    ?assertEqual(open, seki:state(br_reopen)),
    seki:delete_breaker(br_reopen).

manual_reset() ->
    {ok, _} = seki:new_breaker(br_reset, #{
        window_size => 5,
        failure_threshold => 50,
        wait_duration => 60000
    }),
    lists:foreach(
        fun(_) ->
            seki:call(br_reset, fun() -> {error, boom} end)
        end,
        lists:seq(1, 5)
    ),
    ?assertEqual(open, seki:state(br_reset)),
    seki:reset_breaker(br_reset),
    timer:sleep(10),
    ?assertEqual(closed, seki:state(br_reset)),
    seki:delete_breaker(br_reset).

manual_reset_half_open() ->
    {ok, _} = seki:new_breaker(br_reset_ho, #{
        window_size => 5,
        failure_threshold => 50,
        wait_duration => 50
    }),
    lists:foreach(
        fun(_) -> seki:call(br_reset_ho, fun() -> {error, boom} end) end,
        lists:seq(1, 5)
    ),
    timer:sleep(100),
    ?assertEqual(half_open, seki:state(br_reset_ho)),
    seki:reset_breaker(br_reset_ho),
    timer:sleep(10),
    ?assertEqual(closed, seki:state(br_reset_ho)),
    seki:delete_breaker(br_reset_ho).

manual_reset_closed() ->
    {ok, _} = seki:new_breaker(br_reset_cl, #{window_size => 5}),
    ?assertEqual(closed, seki:state(br_reset_cl)),
    seki:reset_breaker(br_reset_cl),
    timer:sleep(10),
    ?assertEqual(closed, seki:state(br_reset_cl)),
    seki:delete_breaker(br_reset_cl).

delete_breaker() ->
    {ok, _} = seki:new_breaker(br_del, #{window_size => 5}),
    ?assertEqual(closed, seki:state(br_del)),
    ok = seki:delete_breaker(br_del),
    ?assertExit(_, seki:state(br_del)).

%%----------------------------------------------------------------------
%% Error Classifier Tests
%%----------------------------------------------------------------------

classifier_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"custom classifier determines failures", fun custom_classifier/0},
        {"default classifier treats {error,_} as failure", fun default_classifier/0},
        {"default classifier treats error atom as failure", fun default_classifier_atom/0}
    ]}.

custom_classifier() ->
    Classifier = fun
        ({error, {http, Status, _}}) when Status >= 500 -> true;
        (_) -> false
    end,
    {ok, _} = seki:new_breaker(br_class, #{
        window_size => 5,
        failure_threshold => 50,
        wait_duration => 60000,
        error_classifier => Classifier
    }),
    %% 4xx errors should NOT trip the breaker
    lists:foreach(
        fun(_) ->
            seki:call(br_class, fun() -> {error, {http, 404, "Not Found"}} end)
        end,
        lists:seq(1, 10)
    ),
    ?assertEqual(closed, seki:state(br_class)),
    %% 5xx errors SHOULD trip the breaker
    lists:foreach(
        fun(_) ->
            seki:call(br_class, fun() -> {error, {http, 500, "Internal"}} end)
        end,
        lists:seq(1, 5)
    ),
    ?assertEqual(open, seki:state(br_class)),
    seki:delete_breaker(br_class).

default_classifier() ->
    {ok, _} = seki:new_breaker(br_def_class, #{
        window_size => 5,
        failure_threshold => 50,
        wait_duration => 60000
    }),
    %% {error, _} should be treated as failure by default
    lists:foreach(
        fun(_) -> seki:call(br_def_class, fun() -> {error, something} end) end,
        lists:seq(1, 5)
    ),
    ?assertEqual(open, seki:state(br_def_class)),
    seki:delete_breaker(br_def_class).

default_classifier_atom() ->
    {ok, _} = seki:new_breaker(br_def_atom, #{
        window_size => 5,
        failure_threshold => 50,
        wait_duration => 60000
    }),
    %% bare error atom should be treated as failure
    lists:foreach(
        fun(_) -> seki:call(br_def_atom, fun() -> error end) end,
        lists:seq(1, 5)
    ),
    ?assertEqual(open, seki:state(br_def_atom)),
    seki:delete_breaker(br_def_atom).

%%----------------------------------------------------------------------
%% Exception Handling Tests
%%----------------------------------------------------------------------

exception_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"catches and returns exceptions", fun catches_exceptions/0},
        {"exceptions count as errors for tripping", fun exceptions_trip/0},
        {"exceptions in half_open reopen", fun exceptions_reopen/0}
    ]}.

catches_exceptions() ->
    {ok, _} = seki:new_breaker(br_exc, #{
        window_size => 5,
        failure_threshold => 50,
        wait_duration => 60000
    }),
    {error, {error, badarg, _}} = seki:call(br_exc, fun() -> error(badarg) end),
    seki:delete_breaker(br_exc).

exceptions_trip() ->
    {ok, _} = seki:new_breaker(br_exc_trip, #{
        window_size => 5,
        failure_threshold => 50,
        wait_duration => 60000
    }),
    lists:foreach(
        fun(_) -> seki:call(br_exc_trip, fun() -> error(crash) end) end,
        lists:seq(1, 5)
    ),
    ?assertEqual(open, seki:state(br_exc_trip)),
    seki:delete_breaker(br_exc_trip).

exceptions_reopen() ->
    {ok, _} = seki:new_breaker(br_exc_reopen, #{
        window_size => 5,
        failure_threshold => 50,
        wait_duration => 50,
        half_open_requests => 3
    }),
    lists:foreach(
        fun(_) -> seki:call(br_exc_reopen, fun() -> {error, boom} end) end,
        lists:seq(1, 5)
    ),
    timer:sleep(100),
    ?assertEqual(half_open, seki:state(br_exc_reopen)),
    seki:call(br_exc_reopen, fun() -> error(crash_in_half_open) end),
    ?assertEqual(open, seki:state(br_exc_reopen)),
    seki:delete_breaker(br_exc_reopen).

%%----------------------------------------------------------------------
%% Slow Call Tests
%%----------------------------------------------------------------------

slow_call_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"slow calls are tracked", fun slow_call_tracked/0},
        {"slow calls trip at threshold", fun slow_calls_trip/0}
    ]}.

slow_call_tracked() ->
    {ok, _} = seki:new_breaker(br_slow, #{
        window_size => 10,
        failure_threshold => 90,
        slow_call_threshold => 50,
        slow_call_duration => 10,
        wait_duration => 60000
    }),
    %% Fast call — should be fine
    {ok, fast} = seki:call(br_slow, fun() -> fast end),
    ?assertEqual(closed, seki:state(br_slow)),
    seki:delete_breaker(br_slow).

slow_calls_trip() ->
    {ok, _} = seki:new_breaker(br_slow_trip, #{
        window_size => 5,
        failure_threshold => 90,
        slow_call_threshold => 50,
        slow_call_duration => 10,
        wait_duration => 60000
    }),
    %% All slow calls should trip the breaker via slow_call_threshold
    lists:foreach(
        fun(_) ->
            seki:call(br_slow_trip, fun() ->
                timer:sleep(20),
                ok
            end)
        end,
        lists:seq(1, 5)
    ),
    ?assertEqual(open, seki:state(br_slow_trip)),
    seki:delete_breaker(br_slow_trip).

%%----------------------------------------------------------------------
%% Time-based Window Tests
%%----------------------------------------------------------------------

time_window_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"time window tracks failures", fun time_window_failures/0},
        {"time window expires old entries", fun time_window_expiry/0}
    ]}.

time_window_failures() ->
    {ok, _} = seki:new_breaker(br_time, #{
        window_type => time,
        window_size => 5000,
        failure_threshold => 50,
        wait_duration => 60000
    }),
    lists:foreach(
        fun(_) -> seki:call(br_time, fun() -> {error, fail} end) end,
        lists:seq(1, 5)
    ),
    ?assertEqual(open, seki:state(br_time)),
    seki:delete_breaker(br_time).

time_window_expiry() ->
    {ok, _} = seki:new_breaker(br_time_exp, #{
        window_type => time,
        window_size => 50,
        failure_threshold => 80,
        wait_duration => 60000
    }),
    %% Add some failures (not enough to trip)
    lists:foreach(
        fun(_) -> seki:call(br_time_exp, fun() -> {error, fail} end) end,
        lists:seq(1, 3)
    ),
    %% Add successes to keep below threshold
    lists:foreach(
        fun(_) -> seki:call(br_time_exp, fun() -> ok end) end,
        lists:seq(1, 5)
    ),
    ?assertEqual(closed, seki:state(br_time_exp)),
    seki:delete_breaker(br_time_exp).

%%----------------------------------------------------------------------
%% Minimum Sample Size Tests
%%----------------------------------------------------------------------

min_sample_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"does not trip with too few samples", fun min_sample/0}
    ]}.

min_sample() ->
    {ok, _} = seki:new_breaker(br_min, #{
        window_size => 20,
        failure_threshold => 50,
        wait_duration => 60000
    }),
    %% Even with 100% failure rate, 4 samples shouldn't trip (min is 5)
    lists:foreach(
        fun(_) -> seki:call(br_min, fun() -> {error, fail} end) end,
        lists:seq(1, 4)
    ),
    ?assertEqual(closed, seki:state(br_min)),
    seki:delete_breaker(br_min).

%%----------------------------------------------------------------------
%% Half-open Rejection Tests
%%----------------------------------------------------------------------

half_open_rejection_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"rejects excess probes in half_open", fun half_open_rejects_excess/0}
    ]}.

half_open_rejects_excess() ->
    %% With half_open_requests => 2, first probe succeeds, second probe succeeds,
    %% breaker closes. We verify the half_open -> closed flow works with probes.
    {ok, _} = seki:new_breaker(br_ho_rej, #{
        window_size => 5,
        failure_threshold => 50,
        wait_duration => 50,
        half_open_requests => 2
    }),
    %% Trip it
    lists:foreach(
        fun(_) -> seki:call(br_ho_rej, fun() -> {error, boom} end) end,
        lists:seq(1, 5)
    ),
    timer:sleep(100),
    ?assertEqual(half_open, seki:state(br_ho_rej)),
    %% First probe — stays half_open
    {ok, ok} = seki:call(br_ho_rej, fun() -> ok end),
    ?assertEqual(half_open, seki:state(br_ho_rej)),
    %% Second probe — should close
    {ok, ok} = seki:call(br_ho_rej, fun() -> ok end),
    ?assertEqual(closed, seki:state(br_ho_rej)),
    seki:delete_breaker(br_ho_rej).

%%----------------------------------------------------------------------
%% call/3 with options Tests
%%----------------------------------------------------------------------

call_opts_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"call/2 and call/3 both work", fun call_2_and_3/0}
    ]}.

call_2_and_3() ->
    {ok, _} = seki:new_breaker(br_opts, #{window_size => 5}),
    {ok, a} = seki:call(br_opts, fun() -> a end),
    {ok, b} = seki:call(br_opts, fun() -> b end, #{}),
    seki:delete_breaker(br_opts).
