-module(seki_ets_worker_tests).

-include_lib("eunit/include/eunit.hrl").

-export([conflict_once_step/4, conflict_then_crash_step/4]).

worker_test_() ->
    {setup, fun() -> {ok, _} = application:ensure_all_started(seki) end,
        fun(_) -> application:stop(seki) end, [
            {"one worker per scheduler", fun workers_started/0},
            {"contended key runs on its worker", fun contended_key_runs_on_worker/0},
            {"errors in a step reach the caller", fun step_error_reaches_caller/0},
            {"stopped workers fall back to a local loop", fun stopped_worker_falls_back/0}
        ]}.

workers_started() ->
    Names = seki_ets_worker:names(),
    ?assertEqual(erlang:system_info(schedulers_online), length(Names)),
    ?assert(lists:all(fun erlang:is_pid/1, [whereis(Name) || Name <:- Names])).

contended_key_runs_on_worker() ->
    {Tab, Counter} = setup_conflict(),
    {ok, Pid} = seki_ets:atomic_update(
        Tab, key, {?MODULE, conflict_once_step, [Tab, key, Counter]}
    ),
    ?assert(lists:member(Pid, [whereis(Name) || Name <:- seki_ets_worker:names()])),
    ?assertEqual([{key, done}], ets:lookup(Tab, key)).

step_error_reaches_caller() ->
    {Tab, Counter} = setup_conflict(),
    ?assertError(
        boom,
        seki_ets:atomic_update(Tab, key, {?MODULE, conflict_then_crash_step, [Tab, key, Counter]})
    ),
    ?assert(lists:all(fun erlang:is_pid/1, [whereis(Name) || Name <:- seki_ets_worker:names()])).

stopped_worker_falls_back() ->
    {Tab, Counter} = setup_conflict(),
    ok = application:stop(seki),
    try
        {ok, Pid} = seki_ets:atomic_update(
            Tab, key, {?MODULE, conflict_once_step, [Tab, key, Counter]}
        ),
        ?assertEqual(self(), Pid)
    after
        {ok, _} = application:ensure_all_started(seki)
    end.

setup_conflict() ->
    Tab = ets:new(?MODULE, [set, public]),
    true = ets:insert(Tab, {key, 0}),
    {Tab, counters:new(1, [])}.

conflict_once_step(_Current, Tab, Key, Counter) ->
    case counters:get(Counter, 1) of
        0 ->
            counters:add(Counter, 1, 1),
            true = ets:insert(Tab, {Key, make_ref()}),
            {self(), {write, lost}};
        _ ->
            {self(), {write, done}}
    end.

conflict_then_crash_step(Current, Tab, Key, Counter) ->
    case counters:get(Counter, 1) of
        0 -> conflict_once_step(Current, Tab, Key, Counter);
        _ -> error(boom)
    end.
