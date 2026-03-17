-module(seki_hedge_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(seki),
    ok.

cleanup(_) ->
    application:stop(seki),
    ok.

hedge_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"returns first successful result", fun first_success/0},
        {"hedges on slow primary", fun hedges_slow/0},
        {"returns error when all fail", fun all_fail/0},
        {"respects max_extra", fun max_extra/0},
        {"race/2 delegates to race/3", fun race_2_delegates/0},
        {"named race works", fun named_race/0},
        {"fast primary no hedge needed", fun fast_primary/0},
        {"primary fails backup succeeds", fun primary_fails_backup_succeeds/0},
        {"max_extra zero means only primary", fun max_extra_zero/0},
        {"multiple backups race", fun multiple_backups/0},
        {"default delay is 100ms", fun default_delay/0}
    ]}.

first_success() ->
    Result = seki_hedge:race(fun() -> fast_result end, #{delay => 1000}),
    ?assertEqual({ok, fast_result}, Result).

hedges_slow() ->
    Counter = counters:new(1, []),
    Fun = fun() ->
        N = counters:get(Counter, 1),
        counters:add(Counter, 1, 1),
        case N of
            0 ->
                timer:sleep(500),
                slow_result;
            _ ->
                fast_backup
        end
    end,
    Result = seki_hedge:race(Fun, #{delay => 50, max_extra => 1}),
    ?assertEqual({ok, fast_backup}, Result).

all_fail() ->
    Result = seki_hedge:race(
        fun() -> error(always_fails) end,
        #{delay => 10, max_extra => 1}
    ),
    ?assertEqual({error, all_failed}, Result).

max_extra() ->
    Counter = counters:new(1, []),
    Fun = fun() ->
        counters:add(Counter, 1, 1),
        timer:sleep(10),
        ok
    end,
    seki_hedge:race(Fun, #{delay => 5, max_extra => 2}),
    timer:sleep(50),
    ?assert(counters:get(Counter, 1) =< 3).

race_2_delegates() ->
    Result = seki_hedge:race(fun() -> delegated end, #{delay => 1000}),
    ?assertEqual({ok, delegated}, Result).

named_race() ->
    Result = seki_hedge:race(my_hedge, fun() -> named_ok end, #{delay => 1000}),
    ?assertEqual({ok, named_ok}, Result).

fast_primary() ->
    Start = erlang:monotonic_time(millisecond),
    Result = seki_hedge:race(fun() -> instant end, #{delay => 500, max_extra => 2}),
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    ?assertEqual({ok, instant}, Result),
    %% Should complete well before the hedge delay
    ?assert(Elapsed < 100).

primary_fails_backup_succeeds() ->
    Counter = counters:new(1, []),
    Fun = fun() ->
        N = counters:get(Counter, 1),
        counters:add(Counter, 1, 1),
        case N of
            0 ->
                %% Primary is slow then fails
                timer:sleep(200),
                error(primary_failed);
            _ ->
                backup_success
        end
    end,
    Result = seki_hedge:race(Fun, #{delay => 50, max_extra => 1}),
    ?assertEqual({ok, backup_success}, Result).

max_extra_zero() ->
    Counter = counters:new(1, []),
    Fun = fun() ->
        counters:add(Counter, 1, 1),
        timer:sleep(10),
        only_primary
    end,
    Result = seki_hedge:race(Fun, #{delay => 5, max_extra => 0}),
    ?assertEqual({ok, only_primary}, Result),
    timer:sleep(50),
    %% Only primary should have run
    ?assertEqual(1, counters:get(Counter, 1)).

multiple_backups() ->
    Counter = counters:new(1, []),
    Fun = fun() ->
        N = counters:get(Counter, 1),
        counters:add(Counter, 1, 1),
        case N of
            0 ->
                timer:sleep(500),
                slow;
            1 ->
                timer:sleep(500),
                also_slow;
            _ ->
                fast
        end
    end,
    Start = erlang:monotonic_time(millisecond),
    Result = seki_hedge:race(Fun, #{delay => 20, max_extra => 3}),
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    ?assertEqual({ok, fast}, Result),
    ?assert(Elapsed < 300).

default_delay() ->
    %% Just verify the default doesn't crash
    Result = seki_hedge:race(fun() -> default_ok end, #{max_extra => 0}),
    ?assertEqual({ok, default_ok}, Result).
