-module(seki_retry_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(seki),
    ok.

cleanup(_) ->
    application:stop(seki),
    ok.

retry_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"succeeds on first attempt", fun succeeds_first/0},
        {"retries on error and succeeds", fun retries_and_succeeds/0},
        {"exhausts max attempts", fun exhausts_attempts/0},
        {"catches exceptions", fun catches_exceptions/0},
        {"exponential backoff", fun exponential_backoff/0},
        {"custom retry_on predicate", fun custom_retry_on/0},
        {"on_retry callback", fun on_retry_callback/0}
    ]}.

succeeds_first() ->
    Result = seki_retry:run(fun() -> ok end, #{max_attempts => 3}),
    ?assertEqual({ok, ok}, Result).

retries_and_succeeds() ->
    Counter = counters:new(1, []),
    Fun = fun() ->
        counters:add(Counter, 1, 1),
        case counters:get(Counter, 1) of
            3 -> success;
            _ -> {error, not_yet}
        end
    end,
    Result = seki_retry:run(Fun, #{
        max_attempts => 5,
        base_delay => 1,
        backoff => constant,
        jitter => none
    }),
    ?assertEqual({ok, success}, Result),
    ?assertEqual(3, counters:get(Counter, 1)).

exhausts_attempts() ->
    Result = seki_retry:run(fun() -> {error, always_fails} end, #{
        max_attempts => 3,
        base_delay => 1,
        backoff => constant,
        jitter => none
    }),
    ?assertMatch({error, {error, always_fails}}, Result).

catches_exceptions() ->
    Result = seki_retry:run(fun() -> error(boom) end, #{
        max_attempts => 2,
        base_delay => 1,
        backoff => constant,
        jitter => none
    }),
    ?assertMatch({error, {error, boom, _}}, Result).

exponential_backoff() ->
    %% Just verify it doesn't crash with exponential backoff
    Result = seki_retry:run(fun() -> {error, fail} end, #{
        max_attempts => 3,
        base_delay => 1,
        max_delay => 100,
        backoff => exponential,
        jitter => full
    }),
    ?assertMatch({error, _}, Result).

custom_retry_on() ->
    %% Only retry on specific errors
    Counter = counters:new(1, []),
    Fun = fun() ->
        counters:add(Counter, 1, 1),
        case counters:get(Counter, 1) of
            1 -> {error, retryable};
            _ -> {error, permanent}
        end
    end,
    RetryOn = fun
        ({error, retryable}) -> true;
        (_) -> false
    end,
    Result = seki_retry:run(Fun, #{
        max_attempts => 5,
        base_delay => 1,
        backoff => constant,
        jitter => none,
        retry_on => RetryOn
    }),
    %% Should stop retrying on permanent error
    ?assertEqual({ok, {error, permanent}}, Result),
    ?assertEqual(2, counters:get(Counter, 1)).

on_retry_callback() ->
    Collector = ets:new(retry_events, [set, public]),
    OnRetry = fun(Attempt, _Error, Delay) ->
        ets:insert(Collector, {Attempt, Delay}),
        ok
    end,
    seki_retry:run(fun() -> {error, fail} end, #{
        max_attempts => 3,
        base_delay => 1,
        backoff => constant,
        jitter => none,
        on_retry => OnRetry
    }),
    ?assertMatch([{1, _}, {2, _}], lists:sort(ets:tab2list(Collector))),
    ets:delete(Collector).
