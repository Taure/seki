-module(seki_ets_worker_tests).

-include_lib("eunit/include/eunit.hrl").

-export([conflict_once_step/4, conflict_then_crash_step/4]).

worker_test_() ->
    {setup, fun() -> {ok, _} = application:ensure_all_started(seki) end,
        fun(_) -> application:stop(seki) end, [
            {"one worker per scheduler", fun workers_started/0},
            {"no worker has a registered name", fun workers_have_no_name/0},
            {"contended key runs on its worker", fun contended_key_runs_on_worker/0},
            {"errors in a step reach the caller", fun step_error_reaches_caller/0},
            {"a key whose worker is gone is updated by its caller", fun dead_worker_falls_back/0},
            {"a restarted worker takes its keys again", fun restarted_worker_is_used/0},
            {"stopped workers fall back to a local loop", fun stopped_worker_falls_back/0},
            {"an unpublished worker count falls back to a local loop",
                fun unpublished_count_falls_back/0},
            {timeout, 30, {"a step past its deadline is not run", fun expired_step_is_not_run/0}},
            {"unknown calls are refused", fun unknown_request_refused/0}
        ]}.

unknown_request_refused() ->
    [Worker | _] = workers(),
    ?assertEqual({error, unknown_request}, gen_server:call(Worker, ping)).

workers_started() ->
    Workers = workers(),
    ?assertEqual(erlang:system_info(schedulers_online), length(Workers)),
    [?assert(is_process_alive(Worker)) || Worker <:- Workers],
    ?assertEqual(length(Workers), length(lists:usort(Workers))),
    Routed = [
        Worker
     || Key <:- lists:seq(1, 1000), {worker, Worker} <:- [seki_ets_worker:route(tab, Key)]
    ],
    ?assertEqual(lists:sort(Workers), lists:usort(Routed)).

workers_have_no_name() ->
    ?assertEqual(
        [], [
            Name
         || Name <:- registered(), string:prefix(atom_to_list(Name), "seki_ets_worker_") =/= nomatch
        ]
    ),
    ?assertEqual(
        [[] || _ <:- workers()],
        [process_info(Worker, registered_name) || Worker <:- workers()]
    ).

contended_key_runs_on_worker() ->
    {Tab, Counter} = setup_conflict(),
    {ok, Pid} = seki_ets:atomic_update(
        Tab, key, {?MODULE, conflict_once_step, [Tab, key, Counter]}
    ),
    ?assertEqual({worker, Pid}, seki_ets_worker:route(Tab, key)),
    ?assert(lists:member(Pid, workers())),
    ?assertEqual([{key, done}], ets:lookup(Tab, key)).

step_error_reaches_caller() ->
    {Tab, Counter} = setup_conflict(),
    ?assertError(
        boom,
        seki_ets:atomic_update(Tab, key, {?MODULE, conflict_then_crash_step, [Tab, key, Counter]})
    ),
    [?assert(is_process_alive(Worker)) || Worker <:- workers()].

dead_worker_falls_back() ->
    {Tab, Counter} = setup_conflict(),
    {worker, Worker} = seki_ets_worker:route(Tab, key),
    ok = sys:suspend(seki_sup),
    try
        ok = stopped(Worker),
        ?assertEqual({worker, Worker}, seki_ets_worker:route(Tab, key)),
        {ok, Pid} = seki_ets:atomic_update(
            Tab, key, {?MODULE, conflict_once_step, [Tab, key, Counter]}
        ),
        ?assertEqual(self(), Pid),
        ?assertEqual([{key, done}], ets:lookup(Tab, key))
    after
        ok = sys:resume(seki_sup)
    end,
    ?assertNotEqual(Worker, rerouted(Tab, key, Worker)).

restarted_worker_is_used() ->
    {Tab, Counter} = setup_conflict(),
    {worker, Worker} = seki_ets_worker:route(Tab, key),
    Before = workers(),
    ok = stopped(Worker),
    Restarted = rerouted(Tab, key, Worker),
    ?assertEqual(Before -- [Worker], workers() -- [Restarted]),
    ?assertEqual(
        {ok, Restarted},
        seki_ets:atomic_update(Tab, key, {?MODULE, conflict_once_step, [Tab, key, Counter]})
    ).

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

unpublished_count_falls_back() ->
    {Tab, Counter} = setup_conflict(),
    Count = persistent_term:get({seki_ets_worker, count}),
    true = persistent_term:erase({seki_ets_worker, count}),
    try
        ?assertEqual(local, seki_ets_worker:route(Tab, key)),
        {ok, Pid} = seki_ets:atomic_update(
            Tab, key, {?MODULE, conflict_once_step, [Tab, key, Counter]}
        ),
        ?assertEqual(self(), Pid)
    after
        ok = persistent_term:put({seki_ets_worker, count}, Count)
    end.

expired_step_is_not_run() ->
    {Tab, Counter} = setup_conflict(),
    {worker, Worker} = seki_ets_worker:route(Tab, key),
    ok = sys:suspend(Worker),
    {Result, Interfering} =
        try
            {
                seki_ets:atomic_update(
                    Tab, key, {?MODULE, conflict_once_step, [Tab, key, Counter]}
                ),
                ets:lookup(Tab, key)
            }
        after
            ok = sys:resume(Worker)
        end,
    _ = sys:get_state(Worker),
    ?assertEqual({error, contention}, Result),
    ?assertEqual(Interfering, ets:lookup(Tab, key)).

-spec workers() -> [pid()].
workers() ->
    [Worker || Child <:- supervisor:which_children(seki_sup), Worker <:- worker(Child)].

-spec worker(term()) -> [pid()].
worker({{seki_ets_worker, _Index}, Worker, worker, _Modules}) when is_pid(Worker) -> [Worker];
worker(_Other) -> [].

stopped(Pid) ->
    Monitor = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', Monitor, process, Pid, _Reason} -> ok
    after 5000 -> error({still_alive, Pid})
    end.

rerouted(Tab, Key, Old) ->
    rerouted(Tab, Key, Old, 100).

rerouted(Tab, Key, Old, 0) ->
    error({not_rerouted, Tab, Key, Old});
rerouted(Tab, Key, Old, Tries) ->
    case seki_ets_worker:route(Tab, Key) of
        {worker, Worker} when Worker =/= Old ->
            Worker;
        _ ->
            timer:sleep(20),
            rerouted(Tab, Key, Old, Tries - 1)
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
