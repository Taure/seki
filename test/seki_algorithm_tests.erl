-module(seki_algorithm_tests).

-include_lib("eunit/include/eunit.hrl").

-define(LIMIT, 10).
-define(WINDOW, 1000).

stale_now_never_rolls_back_test_() ->
    [
        {atom_to_list(Algorithm), fun() -> stale_now_never_rolls_back(Algorithm) end}
     || Algorithm <:- [token_bucket, leaky_bucket, sliding_window, gcra]
    ].

stale_now_never_rolls_back(Algorithm) ->
    {_, Drained} = count_allowed(Algorithm, not_found, 0, 2 * ?LIMIT, 0),
    ?assertMatch(N when N =< ?LIMIT, stale_then_fresh(Algorithm, Drained, 5, 0)).

stale_then_fresh(_Algorithm, _State, 0, Allowed) ->
    Allowed;
stale_then_fresh(Algorithm, State0, Rounds, Allowed) ->
    {_, State1} = check(Algorithm, State0, 0),
    {Fresh, State2} = count_allowed(Algorithm, State1, ?WINDOW, 2 * ?LIMIT, 0),
    stale_then_fresh(Algorithm, State2, Rounds - 1, Allowed + Fresh).

count_allowed(_Algorithm, State, _Now, 0, Allowed) ->
    {Allowed, State};
count_allowed(Algorithm, State0, Now, N, Allowed) ->
    case check(Algorithm, State0, Now) of
        {{allow, _}, State1} -> count_allowed(Algorithm, State1, Now, N - 1, Allowed + 1);
        {{deny, _}, State1} -> count_allowed(Algorithm, State1, Now, N - 1, Allowed)
    end.

check(Algorithm, State, Now) ->
    case seki_algorithm:step(State, Algorithm, 1, Now, config(Algorithm)) of
        {Result, keep} -> {Result, State};
        {Result, {write, Value}} -> {Result, {ok, Value}}
    end.

config(gcra) ->
    Interval = ?WINDOW / ?LIMIT,
    #{
        limit => ?LIMIT,
        window => ?WINDOW,
        emission_interval => Interval,
        burst_tolerance => Interval * (?LIMIT - 1)
    };
config(_) ->
    #{limit => ?LIMIT, window => ?WINDOW, burst => ?LIMIT}.
