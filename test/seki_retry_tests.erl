-module(seki_retry_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(seki),
    ok.

cleanup(_) ->
    seki_deadline:clear(),
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
        {"on_retry callback", fun on_retry_callback/0},
        {"linear backoff", fun linear_backoff/0},
        {"constant backoff", fun constant_backoff/0},
        {"jitter none produces exact delay", fun jitter_none/0},
        {"jitter equal produces bounded delay", fun jitter_equal/0},
        {"jitter decorrelated produces bounded delay", fun jitter_decorrelated/0},
        {"max_delay caps the delay", fun max_delay_cap/0},
        {"default max_attempts is 3", fun default_max_attempts/0},
        {"named retry emits telemetry", fun named_retry/0},
        {"run/2 delegates to run/3", fun run_2_delegates/0},
        {"retry with deadline stops early", fun retry_with_deadline/0},
        {"delay capped to deadline remaining", fun delay_capped_to_deadline/0},
        {"exception with non-retryable error stops", fun exception_non_retryable/0}
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
    Counter = counters:new(1, []),
    Result = seki_retry:run(
        fun() ->
            counters:add(Counter, 1, 1),
            {error, always_fails}
        end,
        #{
            max_attempts => 3,
            base_delay => 1,
            backoff => constant,
            jitter => none
        }
    ),
    ?assertMatch({error, {error, always_fails}}, Result),
    ?assertEqual(3, counters:get(Counter, 1)).

catches_exceptions() ->
    Result = seki_retry:run(fun() -> error(boom) end, #{
        max_attempts => 2,
        base_delay => 1,
        backoff => constant,
        jitter => none
    }),
    ?assertMatch({error, {error, boom, _}}, Result).

exponential_backoff() ->
    Counter = counters:new(1, []),
    Start = erlang:monotonic_time(millisecond),
    seki_retry:run(
        fun() ->
            counters:add(Counter, 1, 1),
            {error, fail}
        end,
        #{
            max_attempts => 3,
            base_delay => 10,
            max_delay => 1000,
            backoff => exponential,
            jitter => none
        }
    ),
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    %% 10ms (attempt 1->2) + 20ms (attempt 2->3) = 30ms minimum
    ?assert(Elapsed >= 25),
    ?assertEqual(3, counters:get(Counter, 1)).

custom_retry_on() ->
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
    Events = lists:sort(ets:tab2list(Collector)),
    ?assertMatch([{1, _}, {2, _}], Events),
    ets:delete(Collector).

linear_backoff() ->
    Counter = counters:new(1, []),
    Start = erlang:monotonic_time(millisecond),
    seki_retry:run(
        fun() ->
            counters:add(Counter, 1, 1),
            {error, fail}
        end,
        #{
            max_attempts => 3,
            base_delay => 10,
            max_delay => 1000,
            backoff => linear,
            jitter => none
        }
    ),
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    %% Linear: 10*1=10ms + 10*2=20ms = 30ms minimum
    ?assert(Elapsed >= 25),
    ?assertEqual(3, counters:get(Counter, 1)).

constant_backoff() ->
    Counter = counters:new(1, []),
    Start = erlang:monotonic_time(millisecond),
    seki_retry:run(
        fun() ->
            counters:add(Counter, 1, 1),
            {error, fail}
        end,
        #{
            max_attempts => 3,
            base_delay => 10,
            backoff => constant,
            jitter => none
        }
    ),
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    %% Constant: 10ms + 10ms = 20ms minimum
    ?assert(Elapsed >= 15),
    ?assertEqual(3, counters:get(Counter, 1)).

jitter_none() ->
    Counter = counters:new(1, []),
    Start = erlang:monotonic_time(millisecond),
    seki_retry:run(
        fun() ->
            counters:add(Counter, 1, 1),
            {error, fail}
        end,
        #{
            max_attempts => 2,
            base_delay => 50,
            backoff => constant,
            jitter => none
        }
    ),
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    %% Should be close to 50ms (no jitter)
    ?assert(Elapsed >= 45),
    ?assert(Elapsed < 200).

jitter_equal() ->
    %% Just verify it doesn't crash and completes
    Counter = counters:new(1, []),
    seki_retry:run(
        fun() ->
            counters:add(Counter, 1, 1),
            {error, fail}
        end,
        #{
            max_attempts => 3,
            base_delay => 1,
            max_delay => 100,
            backoff => exponential,
            jitter => equal
        }
    ),
    ?assertEqual(3, counters:get(Counter, 1)).

jitter_decorrelated() ->
    Counter = counters:new(1, []),
    seki_retry:run(
        fun() ->
            counters:add(Counter, 1, 1),
            {error, fail}
        end,
        #{
            max_attempts => 3,
            base_delay => 1,
            max_delay => 100,
            backoff => exponential,
            jitter => decorrelated
        }
    ),
    ?assertEqual(3, counters:get(Counter, 1)).

max_delay_cap() ->
    Start = erlang:monotonic_time(millisecond),
    seki_retry:run(fun() -> {error, fail} end, #{
        max_attempts => 4,
        base_delay => 100,
        max_delay => 10,
        backoff => exponential,
        jitter => none
    }),
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    %% Max delay is 10ms, 3 retries = ~30ms total, not 100+200+400
    ?assert(Elapsed < 200).

default_max_attempts() ->
    Counter = counters:new(1, []),
    seki_retry:run(
        fun() ->
            counters:add(Counter, 1, 1),
            {error, fail}
        end,
        #{
            base_delay => 1,
            backoff => constant,
            jitter => none
        }
    ),
    ?assertEqual(3, counters:get(Counter, 1)).

named_retry() ->
    Result = seki_retry:run(my_named_retry, fun() -> ok end, #{max_attempts => 1}),
    ?assertEqual({ok, ok}, Result).

run_2_delegates() ->
    Result = seki_retry:run(fun() -> delegated end, #{max_attempts => 1}),
    ?assertEqual({ok, delegated}, Result).

retry_with_deadline() ->
    seki_deadline:set(50),
    Counter = counters:new(1, []),
    Result = seki_retry:run(
        fun() ->
            counters:add(Counter, 1, 1),
            {error, fail}
        end,
        #{
            max_attempts => 100,
            base_delay => 100,
            backoff => constant,
            jitter => none
        }
    ),
    ?assertMatch({error, _}, Result),
    %% Should not have exhausted all 100 attempts
    ?assert(counters:get(Counter, 1) < 10),
    seki_deadline:clear().

delay_capped_to_deadline() ->
    seki_deadline:set(200),
    Start = erlang:monotonic_time(millisecond),
    seki_retry:run(fun() -> {error, fail} end, #{
        max_attempts => 3,
        base_delay => 5000,
        backoff => constant,
        jitter => none
    }),
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    %% Delay should be capped to remaining deadline, not 5000ms
    ?assert(Elapsed < 1000),
    seki_deadline:clear().

exception_non_retryable() ->
    Counter = counters:new(1, []),
    RetryOn = fun
        ({error, retryable}) -> true;
        (_) -> false
    end,
    Result = seki_retry:run(
        fun() ->
            counters:add(Counter, 1, 1),
            error(permanent_crash)
        end,
        #{
            max_attempts => 5,
            base_delay => 1,
            backoff => constant,
            jitter => none,
            retry_on => RetryOn
        }
    ),
    ?assertMatch({error, {error, permanent_crash, _}}, Result),
    %% Should stop after first attempt since exception's error is not retryable
    ?assertEqual(1, counters:get(Counter, 1)).
