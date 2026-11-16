-module(seki_process_sup_tests).

-include_lib("eunit/include/eunit.hrl").

-export([log/2]).

setup() ->
    {ok, _} = application:ensure_all_started(seki),
    ok.

cleanup(_) ->
    application:stop(seki),
    ok.

supervised_bulkhead_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"bulkhead starts under supervisor", fun bulkhead_supervised/0},
        {"adaptive starts under supervisor", fun adaptive_supervised/0},
        {"shed starts under supervisor", fun shed_supervised/0},
        {"health starts under supervisor", fun health_supervised/0},
        {"delete stops the process", fun delete_stops/0},
        {"processes restart on crash", fun restart_on_crash/0},
        {"starting and stopping is logged under the label of the name",
            fun starts_and_stops_are_logged/0}
    ]}.

starts_and_stops_are_logged() ->
    Name = {bulkhead, ~"logged"},
    Label = seki_name:label(Name),
    Level = maps:get(level, logger:get_primary_config()),
    ok = logger:set_primary_config(level, info),
    ok = logger:add_handler(?MODULE, ?MODULE, #{level => info, config => #{pid => self()}}),
    try
        {ok, Pid} = seki:new_bulkhead(Name, #{}),
        ?assertEqual({error, {already_started, Pid}}, seki:new_bulkhead(Name, #{})),
        ?assertEqual(ok, seki:delete_bulkhead(Name)),
        ?assertEqual({error, not_found}, seki:delete_bulkhead(Name)),
        ?assertEqual(
            [
                #{msg => process_started, module => seki_bulkhead, name => Label, pid => Pid},
                #{
                    msg => process_start_failed,
                    module => seki_bulkhead,
                    name => Label,
                    reason => {already_started, Pid}
                },
                #{msg => process_stopped, name => Label},
                #{msg => process_stop_failed, name => Label, reason => not_found}
            ],
            logged()
        )
    after
        ok = logger:remove_handler(?MODULE),
        ok = logger:set_primary_config(level, Level)
    end.

log(#{msg := {report, Report}, meta := #{pid := Pid}}, #{config := #{pid := Pid}}) ->
    Pid ! {logged, Report},
    ok;
log(_Event, _Config) ->
    ok.

logged() ->
    receive
        {logged, Report} -> [Report | logged()]
    after 0 -> []
    end.

bulkhead_supervised() ->
    {ok, Pid} = seki:new_bulkhead(test_bh, #{max_concurrent => 5}),
    ?assert(is_pid(Pid)),
    ?assert(is_process_alive(Pid)),
    {ok, Result} = seki_bulkhead:call(test_bh, fun() -> 42 end),
    ?assertEqual(42, Result),
    ok = seki:delete_bulkhead(test_bh).

adaptive_supervised() ->
    {ok, Pid} = seki:new_adaptive(test_adaptive, #{algorithm => aimd}),
    ?assert(is_pid(Pid)),
    {ok, Result} = seki_adaptive:call(test_adaptive, fun() -> hello end),
    ?assertEqual(hello, Result),
    ok = seki:delete_adaptive(test_adaptive).

shed_supervised() ->
    {ok, Pid} = seki:new_shed(test_shed, #{max_in_flight => 100}),
    ?assert(is_pid(Pid)),
    ok = seki_shed:admit(test_shed),
    seki_shed:complete(test_shed, 1),
    ok = seki:delete_shed(test_shed).

health_supervised() ->
    {ok, Pid} = seki:new_health(test_health, #{vm_checks => false}),
    ?assert(is_pid(Pid)),
    #{health := healthy} = seki_health:check(test_health),
    ok = seki:delete_health(test_health).

delete_stops() ->
    {ok, Pid} = seki:new_bulkhead(test_bh_del, #{max_concurrent => 5}),
    ?assert(is_process_alive(Pid)),
    ok = seki:delete_bulkhead(test_bh_del),
    timer:sleep(50),
    ?assertNot(is_process_alive(Pid)).

restart_on_crash() ->
    {ok, Pid1} = seki:new_bulkhead(test_bh_crash, #{max_concurrent => 5}),
    exit(Pid1, kill),
    timer:sleep(100),
    %% Process should have been restarted with the same name
    Pid2 = whereis(test_bh_crash),
    ?assertNotEqual(undefined, Pid2),
    ?assertNotEqual(Pid1, Pid2),
    ok = seki:delete_bulkhead(test_bh_crash).
