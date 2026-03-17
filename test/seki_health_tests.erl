-module(seki_health_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(seki),
    ok.

cleanup(_) ->
    application:stop(seki),
    ok.

health_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"starts healthy with vm checks", fun starts_healthy/0},
        {"register custom check", fun custom_check/0},
        {"critical check makes unhealthy", fun critical_unhealthy/0},
        {"non-critical check makes degraded", fun non_critical_degraded/0},
        {"liveness returns ok", fun liveness_ok/0},
        {"readiness reflects health", fun readiness_health/0},
        {"unregister check", fun unregister/0},
        {"check_one returns single result", fun check_one/0},
        {"exception in check returns unhealthy", fun exception_check/0}
    ]}.

starts_healthy() ->
    {ok, _} = seki_health:start_link(h_start, #{vm_checks => false, check_interval => 60000}),
    #{health := Health} = seki_health:check(h_start),
    ?assertEqual(healthy, Health),
    gen_server:stop(h_start).

custom_check() ->
    {ok, _} = seki_health:start_link(h_custom, #{vm_checks => false, check_interval => 60000}),
    ok = seki_health:register_check(h_custom, my_db, fun() ->
        {healthy, #{latency_ms => 5}}
    end),
    #{health := healthy, checks := Checks} = seki_health:check(h_custom),
    ?assertMatch(#{my_db := {healthy, _}}, Checks),
    gen_server:stop(h_custom).

critical_unhealthy() ->
    {ok, _} = seki_health:start_link(h_crit, #{vm_checks => false, check_interval => 60000}),
    ok = seki_health:register_check(
        h_crit,
        db,
        fun() ->
            {unhealthy, #{error => connection_refused}}
        end,
        #{critical => true}
    ),
    #{health := Health} = seki_health:check(h_crit),
    ?assertEqual(unhealthy, Health),
    gen_server:stop(h_crit).

non_critical_degraded() ->
    {ok, _} = seki_health:start_link(h_deg, #{vm_checks => false, check_interval => 60000}),
    ok = seki_health:register_check(
        h_deg,
        cache,
        fun() ->
            {unhealthy, #{error => timeout}}
        end,
        #{critical => false}
    ),
    ok = seki_health:register_check(
        h_deg,
        db,
        fun() ->
            {healthy, #{}}
        end,
        #{critical => true}
    ),
    #{health := Health} = seki_health:check(h_deg),
    ?assertEqual(degraded, Health),
    gen_server:stop(h_deg).

liveness_ok() ->
    {ok, _} = seki_health:start_link(h_live, #{check_interval => 60000}),
    ?assertEqual(ok, seki_health:liveness(h_live)),
    gen_server:stop(h_live).

readiness_health() ->
    {ok, _} = seki_health:start_link(h_ready, #{vm_checks => false, check_interval => 60000}),
    ?assertEqual(ok, seki_health:readiness(h_ready)),
    ok = seki_health:register_check(
        h_ready,
        db,
        fun() ->
            {unhealthy, #{}}
        end,
        #{critical => true}
    ),
    ?assertEqual({error, unhealthy}, seki_health:readiness(h_ready)),
    gen_server:stop(h_ready).

unregister() ->
    {ok, _} = seki_health:start_link(h_unreg, #{vm_checks => false, check_interval => 60000}),
    ok = seki_health:register_check(h_unreg, temp, fun() -> {healthy, #{}} end),
    #{checks := Checks1} = seki_health:check(h_unreg),
    ?assert(maps:is_key(temp, Checks1)),
    ok = seki_health:unregister_check(h_unreg, temp),
    #{checks := Checks2} = seki_health:check(h_unreg),
    ?assertNot(maps:is_key(temp, Checks2)),
    gen_server:stop(h_unreg).

check_one() ->
    {ok, _} = seki_health:start_link(h_one, #{vm_checks => false, check_interval => 60000}),
    ok = seki_health:register_check(h_one, db, fun() -> {healthy, #{ok => true}} end),
    ?assertMatch({healthy, _}, seki_health:check_one(h_one, db)),
    ?assertEqual({error, not_found}, seki_health:check_one(h_one, nonexistent)),
    gen_server:stop(h_one).

exception_check() ->
    {ok, _} = seki_health:start_link(h_exc, #{vm_checks => false, check_interval => 60000}),
    ok = seki_health:register_check(h_exc, bad, fun() -> error(kaboom) end, #{critical => true}),
    #{health := Health} = seki_health:check(h_exc),
    ?assertEqual(unhealthy, Health),
    gen_server:stop(h_exc).
