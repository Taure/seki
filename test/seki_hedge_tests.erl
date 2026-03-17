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
        {"respects max_extra", fun max_extra/0}
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
                %% Primary is slow
                timer:sleep(500),
                slow_result;
            _ ->
                %% Backup is fast
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
    %% Should have spawned at most 3 (1 primary + 2 extra)
    ?assert(counters:get(Counter, 1) =< 3).
