-module(seki_ets_worker_tests).

-include_lib("eunit/include/eunit.hrl").

-export([conflict_once_step/4, conflict_then_crash_step/4]).

worker_test_() ->
    {setup, fun() -> {ok, _} = application:ensure_all_started(seki) end,
        fun(_) -> application:stop(seki) end, [
            {"one worker per scheduler", fun workers_started/0},
            {"unexpected messages are dropped", fun unexpected_messages_are_dropped/0},
            {"the first call or cast a worker drops is logged",
                fun first_call_or_cast_dropped_is_logged/0},
            {"no worker has a registered name", fun workers_have_no_name/0},
            {"contended key runs on its worker", fun contended_key_runs_on_worker/0},
            {"errors in a step reach the caller", fun step_error_reaches_caller/0},
            {"a key whose worker is gone is updated by its caller", fun dead_worker_falls_back/0},
            {"a restarted worker takes its keys again", fun restarted_worker_is_used/0},
            {"stopped workers fall back to a local loop", fun stopped_worker_falls_back/0},
            {"an unpublished worker count falls back to a local loop",
                fun unpublished_count_falls_back/0},
            {timeout, 30, {"a step past its deadline is not run", fun expired_step_is_not_run/0}},
            {"a worker is given one second for a step", fun worker_is_given_one_second/0},
            {"a worker count that is no positive integer falls back to a local loop",
                fun unusable_count_falls_back/0},
            {"a worker that was never published falls back to a local loop",
                fun unpublished_worker_falls_back/0},
            {"unknown calls are refused", fun unknown_request_refused/0}
        ]}.

the_worker_count_is_published_when_seki_starts_test() ->
    _ = application:stop(seki),
    _ = persistent_term:erase({seki_ets_worker, count}),
    {ok, _} = application:ensure_all_started(seki),
    try
        ?assertEqual(
            erlang:system_info(schedulers_online), persistent_term:get({seki_ets_worker, count})
        )
    after
        ok = application:stop(seki)
    end.

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

%% A process standing in for the worker of a key answers with the deadline
%% it was sent, which is the moment the call to it is given up.
worker_is_given_one_second() ->
    Tab = ets:new(?MODULE, [set, public]),
    {worker, Worker} = seki_ets_worker:route(Tab, key),
    StandIn = spawn_link(fun answer_with_deadline/0),
    ok = persistent_term:put(published_as(Tab, key), StandIn),
    try
        ?assertEqual({worker, StandIn}, seki_ets_worker:route(Tab, key)),
        ?assertEqual(1000, allowed(Tab))
    after
        ok = persistent_term:put(published_as(Tab, key), Worker),
        StandIn ! stop
    end.

answer_with_deadline() ->
    receive
        {'$gen_call', From, {atomic_update, Deadline, _Tab, _Key, _Step}} ->
            gen_server:reply(From, {ok, Deadline}),
            answer_with_deadline();
        stop ->
            ok
    end.

%% Read only when the call began and ended in the same millisecond, so the
%% deadline is that millisecond plus what the worker is allowed.
allowed(Tab) ->
    Before = erlang:monotonic_time(millisecond),
    {ok, Deadline} = seki_ets_worker:atomic_update(Tab, key, {?MODULE, conflict_once_step, []}),
    case erlang:monotonic_time(millisecond) of
        Before -> Deadline - Before;
        _Later -> allowed(Tab)
    end.

unusable_count_falls_back() ->
    {Tab, Counter} = setup_conflict(),
    Count = persistent_term:get({seki_ets_worker, count}),
    try
        [
            begin
                ok = persistent_term:put({seki_ets_worker, count}, Unusable),
                ?assertEqual(local, seki_ets_worker:route(Tab, key))
            end
         || Unusable <:- [0, -1, 1.0, many]
        ],
        ok = persistent_term:put({seki_ets_worker, count}, 1),
        ?assertEqual(
            {worker, persistent_term:get({seki_ets_worker, 1})}, seki_ets_worker:route(Tab, key)
        ),
        ok = persistent_term:put({seki_ets_worker, count}, 0),
        {ok, Pid} = seki_ets:atomic_update(
            Tab, key, {?MODULE, conflict_once_step, [Tab, key, Counter]}
        ),
        ?assertEqual(self(), Pid)
    after
        ok = persistent_term:put({seki_ets_worker, count}, Count)
    end.

unpublished_worker_falls_back() ->
    {Tab, Counter} = setup_conflict(),
    {worker, Worker} = seki_ets_worker:route(Tab, key),
    true = persistent_term:erase(published_as(Tab, key)),
    try
        ?assertEqual(local, seki_ets_worker:route(Tab, key)),
        {ok, Pid} = seki_ets:atomic_update(
            Tab, key, {?MODULE, conflict_once_step, [Tab, key, Counter]}
        ),
        ?assertEqual(self(), Pid)
    after
        ok = persistent_term:put(published_as(Tab, key), Worker)
    end.

published_as(Tab, Key) ->
    Count = persistent_term:get({seki_ets_worker, count}),
    {seki_ets_worker, erlang:phash2({Tab, Key}, Count) + 1}.

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

first_call_or_cast_dropped_is_logged() ->
    Tab = ets:new(?MODULE, [set, public]),
    [
        begin
            {worker, Worker} = seki_ets_worker:route(Tab, key),
            ok = stopped(Worker),
            ?assertEqual(
                [
                    #{
                        msg => unexpected_message_dropped,
                        module => seki_ets_worker,
                        kind => Kind,
                        message => stray
                    }
                ],
                seki_unexpected_tests:first_dropped(rerouted(Tab, key, Worker), Kind)
            )
        end
     || Kind <:- [call, cast]
    ].

unexpected_messages_are_dropped() ->
    [Worker | _] = workers(),
    ?assertEqual(
        ok,
        seki_unexpected_tests:dropped_by(Worker, seki_ets_worker, {error, unknown_request})
    ).
