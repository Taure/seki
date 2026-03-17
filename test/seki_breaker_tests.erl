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
        {"trips after failure threshold", fun trips_on_failures/0},
        {"rejects calls when open", fun rejects_when_open/0},
        {"transitions to half_open after wait", fun half_open_transition/0},
        {"closes after successful probes", fun closes_after_probes/0},
        {"reopens on half_open failure", fun reopens_on_failure/0},
        {"manual reset works", fun manual_reset/0}
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

trips_on_failures() ->
    {ok, _} = seki:new_breaker(br_trip, #{
        window_size => 5,
        failure_threshold => 50,
        wait_duration => 60000
    }),
    %% Generate failures
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
    %% Trip the breaker
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
    %% Trip the breaker
    lists:foreach(
        fun(_) ->
            seki:call(br_half, fun() -> {error, boom} end)
        end,
        lists:seq(1, 5)
    ),
    ?assertEqual(open, seki:state(br_half)),
    %% Wait for transition to half_open
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
    %% Trip the breaker
    lists:foreach(
        fun(_) ->
            seki:call(br_close, fun() -> {error, boom} end)
        end,
        lists:seq(1, 5)
    ),
    ?assertEqual(open, seki:state(br_close)),
    %% Wait for half_open
    timer:sleep(100),
    ?assertEqual(half_open, seki:state(br_close)),
    %% Successful probes should close the breaker
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
    %% Trip the breaker
    lists:foreach(
        fun(_) ->
            seki:call(br_reopen, fun() -> {error, boom} end)
        end,
        lists:seq(1, 5)
    ),
    %% Wait for half_open
    timer:sleep(100),
    ?assertEqual(half_open, seki:state(br_reopen)),
    %% Failed probe should reopen
    seki:call(br_reopen, fun() -> {error, still_broken} end),
    ?assertEqual(open, seki:state(br_reopen)),
    seki:delete_breaker(br_reopen).

manual_reset() ->
    {ok, _} = seki:new_breaker(br_reset, #{
        window_size => 5,
        failure_threshold => 50,
        wait_duration => 60000
    }),
    %% Trip the breaker
    lists:foreach(
        fun(_) ->
            seki:call(br_reset, fun() -> {error, boom} end)
        end,
        lists:seq(1, 5)
    ),
    ?assertEqual(open, seki:state(br_reset)),
    %% Manual reset should close
    seki:reset_breaker(br_reset),
    timer:sleep(10),
    ?assertEqual(closed, seki:state(br_reset)),
    seki:delete_breaker(br_reset).

%%----------------------------------------------------------------------
%% Error Classifier Tests
%%----------------------------------------------------------------------

classifier_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"custom classifier determines failures", fun custom_classifier/0}
    ]}.

custom_classifier() ->
    %% Only 5xx responses count as failures
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

%%----------------------------------------------------------------------
%% Exception Handling Tests
%%----------------------------------------------------------------------

exception_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"catches and returns exceptions", fun catches_exceptions/0}
    ]}.

catches_exceptions() ->
    {ok, _} = seki:new_breaker(br_exc, #{
        window_size => 5,
        failure_threshold => 50,
        wait_duration => 60000
    }),
    {error, {error, badarg, _}} = seki:call(br_exc, fun() -> error(badarg) end),
    seki:delete_breaker(br_exc).
