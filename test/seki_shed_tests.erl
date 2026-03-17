-module(seki_shed_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(seki),
    ok.

cleanup(_) ->
    application:stop(seki),
    ok.

shed_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"admits requests under capacity", fun admits_under_capacity/0},
        {"sheds when at capacity", fun sheds_at_capacity/0},
        {"p0 always admitted", fun p0_always_admitted/0},
        {"priority shedding order", fun priority_order/0},
        {"codel enters dropping on high latency", fun codel_dropping/0},
        {"codel resets on low latency", fun codel_resets/0},
        {"status reports correctly", fun status_reports/0},
        {"complete reduces in_flight", fun complete_reduces/0}
    ]}.

admits_under_capacity() ->
    {ok, _} = seki_shed:start_link(sh_admit, #{max_in_flight => 100}),
    ?assertEqual(ok, seki_shed:admit(sh_admit, 2)),
    ?assertEqual(ok, seki_shed:admit(sh_admit, 2)),
    gen_server:stop(sh_admit).

sheds_at_capacity() ->
    {ok, _} = seki_shed:start_link(sh_shed, #{max_in_flight => 3}),
    ok = seki_shed:admit(sh_shed, 2),
    ok = seki_shed:admit(sh_shed, 2),
    ok = seki_shed:admit(sh_shed, 2),
    ?assertEqual({error, shed}, seki_shed:admit(sh_shed, 2)),
    gen_server:stop(sh_shed).

p0_always_admitted() ->
    {ok, _} = seki_shed:start_link(sh_p0, #{max_in_flight => 2}),
    ok = seki_shed:admit(sh_p0, 2),
    ok = seki_shed:admit(sh_p0, 2),
    %% P2 should be shed at capacity
    ?assertEqual({error, shed}, seki_shed:admit(sh_p0, 2)),
    %% P0 should still be admitted (always)
    ?assertEqual(ok, seki_shed:admit(sh_p0, 0)),
    gen_server:stop(sh_p0).

priority_order() ->
    {ok, _} = seki_shed:start_link(sh_prio, #{
        max_in_flight => 100,
        p1_threshold => 90,
        p2_threshold => 80,
        p3_threshold => 70
    }),
    %% Fill to 75% capacity
    lists:foreach(fun(_) -> seki_shed:admit(sh_prio, 0) end, lists:seq(1, 75)),
    %% P3 (low) should be shed at 70%+
    ?assertEqual({error, shed}, seki_shed:admit(sh_prio, 3)),
    %% P2 (normal) should still be admitted (under 80%)
    ?assertEqual(ok, seki_shed:admit(sh_prio, 2)),
    %% Fill to 85%
    lists:foreach(fun(_) -> seki_shed:admit(sh_prio, 0) end, lists:seq(1, 9)),
    %% P2 should now be shed (over 80%)
    ?assertEqual({error, shed}, seki_shed:admit(sh_prio, 2)),
    %% P1 should still be admitted (under 90%)
    ?assertEqual(ok, seki_shed:admit(sh_prio, 1)),
    gen_server:stop(sh_prio).

codel_dropping() ->
    {ok, _} = seki_shed:start_link(sh_codel, #{
        max_in_flight => 1000,
        target => 5,
        interval => 10
    }),
    %% Simulate high latency completions
    ok = seki_shed:admit(sh_codel, 2),
    seki_shed:complete(sh_codel, 20),
    timer:sleep(15),
    ok = seki_shed:admit(sh_codel, 2),
    seki_shed:complete(sh_codel, 20),
    timer:sleep(15),
    #{dropping := Dropping} = seki_shed:status(sh_codel),
    ?assertEqual(true, Dropping),
    gen_server:stop(sh_codel).

codel_resets() ->
    {ok, _} = seki_shed:start_link(sh_reset, #{
        max_in_flight => 1000,
        target => 5,
        interval => 10
    }),
    %% Enter dropping state
    ok = seki_shed:admit(sh_reset, 0),
    seki_shed:complete(sh_reset, 20),
    timer:sleep(15),
    ok = seki_shed:admit(sh_reset, 0),
    seki_shed:complete(sh_reset, 20),
    timer:sleep(5),
    %% Now send low latency — should reset dropping
    ok = seki_shed:admit(sh_reset, 0),
    seki_shed:complete(sh_reset, 1),
    timer:sleep(5),
    #{dropping := Dropping} = seki_shed:status(sh_reset),
    ?assertEqual(false, Dropping),
    gen_server:stop(sh_reset).

status_reports() ->
    {ok, _} = seki_shed:start_link(sh_stat, #{max_in_flight => 100}),
    ok = seki_shed:admit(sh_stat, 2),
    ok = seki_shed:admit(sh_stat, 2),
    seki_shed:complete(sh_stat, 10),
    timer:sleep(10),
    #{
        in_flight := InFlight,
        total_admitted := Admitted,
        avg_latency_ms := AvgLatency
    } = seki_shed:status(sh_stat),
    ?assertEqual(1, InFlight),
    ?assertEqual(2, Admitted),
    ?assert(AvgLatency > 0),
    gen_server:stop(sh_stat).

complete_reduces() ->
    {ok, _} = seki_shed:start_link(sh_comp, #{max_in_flight => 100}),
    ok = seki_shed:admit(sh_comp, 2),
    ok = seki_shed:admit(sh_comp, 2),
    seki_shed:complete(sh_comp, 5),
    timer:sleep(10),
    #{in_flight := 1} = seki_shed:status(sh_comp),
    seki_shed:complete(sh_comp, 5),
    timer:sleep(10),
    #{in_flight := 0} = seki_shed:status(sh_comp),
    gen_server:stop(sh_comp).
