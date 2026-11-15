-module(seki_breaker_trips_tests).

-include_lib("eunit/include/eunit.hrl").

trips_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"a name that never opened is closed", fun never_opened/0},
        {"an open name keeps the time of its next probe", fun opened_then_closed/0},
        {"names are told apart", fun names_are_told_apart/0}
    ]}.

setup() ->
    _ = application:stop(seki),
    ok = seki_breaker_trips:new_table().

cleanup(ok) ->
    true = ets:delete(seki_breaker_trips),
    ok.

never_opened() ->
    ?assertEqual(closed, seki_breaker_trips:probe_at(trip_never)),
    ?assertEqual(ok, seki_breaker_trips:closed(trip_never)).

opened_then_closed() ->
    ?assertEqual(ok, seki_breaker_trips:opened(trip_open, -5000)),
    ?assertEqual(-5000, seki_breaker_trips:probe_at(trip_open)),
    ?assertEqual(ok, seki_breaker_trips:opened(trip_open, 7000)),
    ?assertEqual(7000, seki_breaker_trips:probe_at(trip_open)),
    ?assertEqual(ok, seki_breaker_trips:closed(trip_open)),
    ?assertEqual(closed, seki_breaker_trips:probe_at(trip_open)).

names_are_told_apart() ->
    ok = seki_breaker_trips:opened({trip, 1}, 10),
    ok = seki_breaker_trips:opened({trip, 1.0}, 20),
    ok = seki_breaker_trips:opened(~"trip", 30),
    ?assertEqual(10, seki_breaker_trips:probe_at({trip, 1})),
    ?assertEqual(20, seki_breaker_trips:probe_at({trip, 1.0})),
    ?assertEqual(30, seki_breaker_trips:probe_at(~"trip")),
    ok = seki_breaker_trips:closed({trip, 1}),
    ?assertEqual(closed, seki_breaker_trips:probe_at({trip, 1})),
    ?assertEqual(20, seki_breaker_trips:probe_at({trip, 1.0})).

without_the_table_test_() ->
    {setup, fun() -> application:stop(seki) end, fun(_) -> ok end, [
        {"nothing is kept and nothing fails", fun nothing_is_kept/0},
        {"a breaker started on its own still trips", fun breaker_on_its_own/0}
    ]}.

nothing_is_kept() ->
    ?assertEqual(undefined, ets:whereis(seki_breaker_trips)),
    ?assertEqual(ok, seki_breaker_trips:opened(trip_no_table, 10)),
    ?assertEqual(closed, seki_breaker_trips:probe_at(trip_no_table)),
    ?assertEqual(ok, seki_breaker_trips:closed(trip_no_table)).

breaker_on_its_own() ->
    {ok, _} = application:ensure_all_started(telemetry),
    {ok, Breaker} = seki_breaker:start_link(trip_alone, #{window_size => 1, wait_duration => 60000}),
    ?assertEqual(closed, seki_breaker:get_state(trip_alone)),
    ?assertEqual({ok, error}, seki_breaker:call(trip_alone, fun() -> error end, #{})),
    ?assertEqual(open, seki_breaker:get_state(trip_alone)),
    seki_breaker:reset(trip_alone),
    ?assertEqual(closed, seki_breaker:get_state(trip_alone)),
    ok = gen_statem:stop(Breaker).
