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
        {"options of the wrong kind are refused", fun invalid_options_are_refused/0},
        {"unexpected messages are dropped", fun unexpected_messages_are_dropped/0},
        {"starts healthy with vm checks", fun starts_healthy/0},
        {"register custom check", fun custom_check/0},
        {"critical check makes unhealthy", fun critical_unhealthy/0},
        {"non-critical check makes degraded", fun non_critical_degraded/0},
        {"liveness returns ok", fun liveness_ok/0},
        {"readiness reflects health", fun readiness_health/0},
        {"unregister check", fun unregister/0},
        {"check_one returns single result", fun check_one/0},
        {"exception in check returns unhealthy", fun exception_check/0},
        {"vm checks run and report", fun vm_checks_run/0},
        {"a check that returns no health is unhealthy", fun invalid_result/0}
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

vm_checks_run() ->
    {ok, _} = seki_health:start_link(h_vm, #{check_interval => 60000}),
    ?assertMatch(
        {healthy, #{total_mb := Total, process_mb := Processes}} when
            is_integer(Total) andalso is_integer(Processes),
        seki_health:check_one(h_vm, vm_memory)
    ),
    ?assertMatch(
        {_, #{count := _, limit := _, utilization := _}},
        seki_health:check_one(h_vm, vm_processes)
    ),
    ?assertMatch(
        {_, #{total_run_queue := _, schedulers := _, per_scheduler := _}},
        seki_health:check_one(h_vm, vm_run_queue)
    ),
    #{checks := Checks} = seki_health:check(h_vm),
    ?assertEqual([vm_memory, vm_processes, vm_run_queue], lists:sort(maps:keys(Checks))),
    gen_server:stop(h_vm).

invalid_result() ->
    {ok, Checker} = seki_health:start_link(h_invalid, #{
        vm_checks => false, check_interval => 60000
    }),
    Checks = #{
        no_tuple => ok,
        no_health => {fine, #{}},
        no_details => {healthy, none}
    },
    [
        ok = seki_health:register_check(h_invalid, CheckName, returning(Returned))
     || CheckName := Returned <:- Checks
    ],
    ?assertMatch(
        #{health := degraded, checks := #{no_tuple := {unhealthy, _}}},
        seki_health:check(h_invalid)
    ),
    [
        ?assertEqual(
            {unhealthy, #{error => {invalid_result, Returned}}},
            seki_health:check_one(h_invalid, CheckName)
        )
     || CheckName := Returned <:- Checks
    ],
    ?assertEqual(Checker, whereis(h_invalid)),
    gen_server:stop(h_invalid).

returning(Returned) ->
    fun() -> Returned end.

unexpected_messages_are_dropped() ->
    {ok, Pid} = seki_health:start_link(h_stray, #{vm_checks => false, check_interval => 60000}),
    ?assertEqual(ok, seki_unexpected_tests:dropped_by(Pid, seki_health, {error, unknown})).

invalid_options_are_refused() ->
    Supervisor = whereis(seki_process_sup),
    [
        begin
            ?assertEqual(
                {error, {invalid_option, Key}}, seki:new_health(h_invalid, option(Key, Value))
            ),
            ?assertEqual(
                {error, {invalid_option, Key}},
                seki_health:start_link(h_invalid, option(Key, Value))
            )
        end
     || {Key, Value} <:- [
            {vm_checks, yes}, {check_interval, 0}, {check_interval, never}
        ]
    ],
    ?assertEqual({error, invalid_options}, seki_health:check_options([])),
    ?assertEqual(undefined, whereis(h_invalid)),
    ?assertEqual(Supervisor, whereis(seki_process_sup)),
    {ok, _} = seki:new_health(h_invalid, #{
        vm_checks => false, check_interval => 1, some_other_key => kept
    }),
    ?assertEqual(ok, seki_health:readiness(h_invalid)),
    seki:delete_health(h_invalid).

-spec option(atom(), term()) -> map().
option(Key, Value) ->
    #{Key => Value}.
