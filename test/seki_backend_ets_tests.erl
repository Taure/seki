-module(seki_backend_ets_tests).

-include_lib("eunit/include/eunit.hrl").

non_literal_key_is_not_a_table_scan_test_() ->
    {timeout, 60, fun non_literal_key_is_not_a_table_scan/0}.

non_literal_key_is_not_a_table_scan() ->
    {ok, Tab} = seki_backend_ets:init(#{table_name => scan_test}),
    try
        _ = [ok = seki_backend_ets:put(Tab, {row, N}, N) || N <:- lists:seq(1, 100000)],
        Literal = time_updates(Tab, {ip, 1}),
        Map = time_updates(Tab, #{ip => 1}),
        ?assertMatch(T when T < 10 * Literal + 1000, Map)
    after
        seki_backend_ets:terminate(Tab)
    end.

keys_round_trip_test() ->
    {ok, Tab} = seki_backend_ets:init(#{table_name => round_trip_test}),
    Keys = [
        '_',
        '$1',
        {a, '_'},
        #{ip => 1},
        #{ip => 1, port => 2},
        {seki_escaped_key, term_to_binary(#{ip => 1}, [deterministic])},
        {ip, 1},
        ~"user"
    ],
    try
        _ = [ok = seki_backend_ets:put(Tab, Key, N) || {N, Key} <:- lists:enumerate(Keys)],
        ?assertEqual(
            [{ok, N} || N <:- lists:seq(1, length(Keys))],
            [seki_backend_ets:get(Tab, Key) || Key <:- Keys]
        ),
        ?assertEqual(
            {ok, 11},
            seki_backend_ets:update(Tab, #{ip => 1}, fun(V) when is_integer(V) -> V + 7 end, 0)
        ),
        ?assertEqual({ok, 5}, seki_backend_ets:get(Tab, #{ip => 1, port => 2})),
        ok = seki_backend_ets:delete(Tab, #{ip => 1}),
        ?assertEqual(not_found, seki_backend_ets:get(Tab, #{ip => 1})),
        ?assertEqual(
            {ok, 6},
            seki_backend_ets:get(
                Tab, {seki_escaped_key, term_to_binary(#{ip => 1}, [deterministic])}
            )
        )
    after
        seki_backend_ets:terminate(Tab)
    end.

time_updates(Tab, Key) ->
    {Micros, _} = timer:tc(fun() ->
        [{ok, _} = seki_backend_ets:update(Tab, Key, fun increment/1, 0) || _ <:- lists:seq(1, 100)]
    end),
    Micros.

increment(N) when is_integer(N) -> N + 1.
