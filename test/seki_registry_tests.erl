-module(seki_registry_tests).

-include_lib("eunit/include/eunit.hrl").

-define(NAME, {payments, ~"tenant-1"}).

registry_test_() ->
    {foreach,
        fun() ->
            {ok, _} = application:ensure_all_started(seki),
            ok
        end,
        fun(_) -> application:stop(seki) end, [
            fun an_atom_is_registered_locally/0,
            fun any_other_term_is_registered_here/0,
            fun a_name_is_taken_once/0,
            fun a_name_is_free_once_its_process_is_gone/0,
            fun a_message_reaches_the_named_process/0,
            fun names_outlive_a_restart_of_the_registry/0,
            fun a_breaker_is_named_by_a_term/0,
            fun a_bulkhead_is_named_by_a_term/0,
            fun a_load_shedder_is_named_by_a_term/0,
            fun an_adaptive_limiter_is_named_by_a_term/0,
            fun a_health_checker_is_named_by_a_term/0,
            fun a_limiter_is_named_by_a_term/0,
            fun a_distributed_limiter_named_by_a_term_has_its_own_group/0,
            fun a_named_process_restarts_under_its_name/0,
            fun naming_by_terms_creates_no_atoms/0
        ]}.

an_atom_is_registered_locally() ->
    ?assertEqual({local, my_breaker}, seki_registry:registration(my_breaker)),
    ?assertEqual(my_breaker, seki_registry:server(my_breaker)),
    {ok, Pid} = seki:new_breaker(seki_registry_tests_breaker, #{}),
    ?assertEqual(Pid, whereis(seki_registry_tests_breaker)),
    ?assertEqual(undefined, seki_registry:whereis_name(seki_registry_tests_breaker)),
    ?assertEqual(closed, seki:state(seki_registry_tests_breaker)).

any_other_term_is_registered_here() ->
    ?assertEqual({via, seki_registry, ?NAME}, seki_registry:registration(?NAME)),
    ?assertEqual({via, seki_registry, ?NAME}, seki_registry:server(?NAME)),
    ?assertEqual({via, seki_registry, ~"a binary"}, seki_registry:server(~"a binary")),
    ?assertEqual(undefined, seki_registry:whereis_name(?NAME)),
    ?assertEqual(yes, seki_registry:register_name(?NAME, self())),
    ?assertEqual(self(), seki_registry:whereis_name(?NAME)),
    ?assertEqual(ok, seki_registry:unregister_name(?NAME)),
    ?assertEqual(undefined, seki_registry:whereis_name(?NAME)),
    ?assertEqual(ok, seki_registry:unregister_name(?NAME)).

a_name_is_taken_once() ->
    Other = idle(),
    ?assertEqual(yes, seki_registry:register_name(?NAME, self())),
    ?assertEqual(no, seki_registry:register_name(?NAME, Other)),
    ?assertEqual(self(), seki_registry:whereis_name(?NAME)),
    ?assertEqual(yes, seki_registry:register_name({payments, ~"tenant-2"}, Other)),
    ?assertEqual(Other, seki_registry:whereis_name({payments, ~"tenant-2"})),
    {ok, First} = seki:new_bulkhead(?MODULE, #{max_concurrent => 1}),
    ?assertEqual({error, {already_started, First}}, seki:new_bulkhead(?MODULE, #{})),
    {ok, Named} = seki:new_bulkhead({bulkhead, 1}, #{max_concurrent => 1}),
    ?assertEqual({error, {already_started, Named}}, seki:new_bulkhead({bulkhead, 1}, #{})).

a_name_is_free_once_its_process_is_gone() ->
    Gone = idle(),
    ?assertEqual(yes, seki_registry:register_name(?NAME, Gone)),
    stopped(Gone),
    ?assertEqual(undefined, seki_registry:whereis_name(?NAME)),
    ?assertEqual(yes, seki_registry:register_name(?NAME, self())),
    %% The registry hears of the first process only now, if it has not yet.
    _ = sys:get_state(seki_registry),
    ?assertEqual(self(), seki_registry:whereis_name(?NAME)).

a_message_reaches_the_named_process() ->
    ?assertEqual(yes, seki_registry:register_name(?NAME, self())),
    ?assertEqual(self(), seki_registry:send(?NAME, {hello, ?NAME})),
    ?assertEqual(
        {hello, ?NAME},
        receive
            Message -> Message
        after 1000 -> nothing
        end
    ),
    ?assertExit({badarg, {nobody, hello}}, seki_registry:send(nobody, hello)).

names_outlive_a_restart_of_the_registry() ->
    {ok, Breaker} = seki:new_breaker(?NAME, #{}),
    Registry = whereis(seki_registry),
    stopped(Registry),
    Restarted = restarted(seki_registry, Registry),
    ?assertNotEqual(Registry, Restarted),
    ?assertEqual(Breaker, seki_registry:whereis_name(?NAME)),
    ?assertEqual(closed, seki:state(?NAME)),
    %% And it is still told when the process goes.
    ok = seki:delete_breaker(?NAME),
    _ = sys:get_state(seki_registry),
    ?assertEqual([], ets:lookup(seki_registry, ?NAME)).

a_breaker_is_named_by_a_term() ->
    Name = {breaker, ~"orders", 1},
    {ok, Pid} = seki:new_breaker(Name, #{
        window_size => 5, failure_threshold => 50, wait_duration => 60000
    }),
    ?assertEqual(Pid, seki_registry:whereis_name(Name)),
    ?assertEqual(closed, seki:state(Name)),
    [seki:call(Name, fun() -> {error, down} end) || _ <:- lists:seq(1, 5)],
    ?assertEqual(open, seki:state(Name)),
    ?assertEqual({error, circuit_open}, seki:call(Name, fun() -> 42 end)),
    ok = seki:reset_breaker(Name),
    ?assertEqual(closed, seki:state(Name)),
    ?assertEqual({ok, 42}, seki:call(Name, fun() -> 42 end)),
    ok = seki:delete_breaker(Name),
    ?assertNot(is_process_alive(Pid)),
    ?assertEqual(undefined, seki_registry:whereis_name(Name)),
    {ok, Again} = seki:new_breaker(Name, #{}),
    ?assertEqual(Again, seki_registry:whereis_name(Name)).

a_bulkhead_is_named_by_a_term() ->
    Name = {bulkhead, ~"orders"},
    {ok, _} = seki:new_bulkhead(Name, #{max_concurrent => 1}),
    ?assertEqual(ok, seki_bulkhead:acquire(Name)),
    ?assertEqual({error, bulkhead_full}, seki_bulkhead:acquire(Name)),
    ?assertMatch(#{current := 1, max := 1, available := 0}, seki_bulkhead:status(Name)),
    ?assertEqual(ok, seki_bulkhead:release(Name)),
    ?assertEqual({ok, done}, seki_bulkhead:call(Name, fun() -> done end)),
    ?assertEqual(ok, seki:delete_bulkhead(Name)).

a_load_shedder_is_named_by_a_term() ->
    Name = [shed, ~"orders"],
    {ok, _} = seki:new_shed(Name, #{max_in_flight => 1}),
    ?assertEqual(ok, seki_shed:admit(Name)),
    ?assertMatch(#{in_flight := 1}, seki_shed:status(Name)),
    ?assertEqual(ok, seki_shed:complete(Name, 1)),
    ?assertMatch(#{in_flight := 0}, seki_shed:status(Name)),
    ?assertEqual(ok, seki:delete_shed(Name)).

an_adaptive_limiter_is_named_by_a_term() ->
    Name = {adaptive, 7},
    {ok, _} = seki:new_adaptive(Name, #{algorithm => aimd}),
    ?assertEqual({ok, hello}, seki_adaptive:call(Name, fun() -> hello end)),
    ?assert(is_map(seki_adaptive:status(Name))),
    ?assertEqual(ok, seki:delete_adaptive(Name)).

a_health_checker_is_named_by_a_term() ->
    Name = {health, ~"api"},
    {ok, _} = seki:new_health(Name, #{vm_checks => false}),
    ok = seki_health:register_check(Name, always, fun() -> {healthy, #{}} end),
    ?assertMatch(#{health := healthy}, seki_health:check(Name)),
    ?assertEqual(ok, seki_health:liveness(Name)),
    ?assertEqual(ok, seki_health:readiness(Name)),
    ?assertEqual(ok, seki:delete_health(Name)).

a_limiter_is_named_by_a_term() ->
    Name = {limiter, ~"orders"},
    Other = {limiter, ~"invoices"},
    Opts = #{algorithm => token_bucket, limit => 2, window => 60000},
    ?assertEqual(ok, seki:new_limiter(Name, Opts)),
    ?assertEqual(ok, seki:new_limiter(Other, Opts)),
    ?assertEqual({error, already_registered}, seki:new_limiter(Name, Opts)),
    ?assertMatch({allow, #{remaining := 1}}, seki:check(Name, user)),
    ?assertMatch({allow, #{remaining := 0}}, seki:check(Name, user)),
    ?assertMatch({deny, _}, seki:check(Name, user)),
    %% Two limiters named by terms do not share their counters.
    ?assertMatch({allow, #{remaining := 1}}, seki:check(Other, user)),
    ?assertMatch({allow, #{remaining := 1}}, seki:inspect(Other, user, 1)),
    ?assertEqual(ok, seki:reset(Name, user)),
    ?assertMatch({allow, #{remaining := 1}}, seki:check(Name, user)),
    ?assertEqual(ok, seki:delete_limiter(Name)),
    ?assertError({limiter_not_found, Name}, seki:check(Name, user)),
    ?assertMatch({allow, _}, seki:check(Other, user)).

a_distributed_limiter_named_by_a_term_has_its_own_group() ->
    Opts = #{
        algorithm => sliding_window,
        limit => 5,
        window => 60000,
        backend => seki_backend_pg
    },
    ?assertEqual(ok, seki:new_limiter({pg_limiter, 1}, Opts)),
    ?assertEqual(ok, seki:new_limiter({pg_limiter, 2}, Opts)),
    ?assertEqual(ok, seki:new_limiter(seki_registry_tests_pg, Opts)),
    ?assertMatch([_], pg:get_local_members(seki_pg, {seki_limiters, {pg_limiter, 1}})),
    ?assertMatch([_], pg:get_local_members(seki_pg, {seki_limiters, {pg_limiter, 2}})),
    %% An atom keeps the group it always had.
    ?assertMatch(
        [_],
        pg:get_local_members(seki_pg, {seki_limiters, seki_limiter_seki_registry_tests_pg})
    ),
    ?assertMatch({allow, _}, seki:check({pg_limiter, 1}, user)),
    [
        seki:delete_limiter(Name)
     || Name <:- [{pg_limiter, 1}, {pg_limiter, 2}, seki_registry_tests_pg]
    ].

a_named_process_restarts_under_its_name() ->
    Name = {bulkhead, restarts},
    {ok, First} = seki:new_bulkhead(Name, #{max_concurrent => 1}),
    stopped(First),
    Second = restarted(Name, First),
    ?assertNotEqual(First, Second),
    ?assertEqual({ok, done}, seki_bulkhead:call(Name, fun() -> done end)).

naming_by_terms_creates_no_atoms() ->
    %% Whatever these calls load is loaded by the first round.
    Round = fun(Number) ->
        Name = {tenant, Number},
        {ok, _} = seki:new_breaker(Name, #{}),
        {ok, _} = seki:new_bulkhead({bulkhead, Name}, #{max_concurrent => 1}),
        ok = seki:new_limiter(Name, #{algorithm => gcra, limit => 5, window => 1000}),
        {allow, _} = seki:check(Name, user),
        {ok, ok} = seki:call(Name, fun() -> ok end)
    end,
    Round(0),
    Before = erlang:system_info(atom_count),
    [Round(Number) || Number <:- lists:seq(1, 50)],
    ?assertEqual(Before, erlang:system_info(atom_count)).

idle() ->
    spawn(fun() ->
        receive
            stop -> ok
        end
    end).

stopped(Pid) ->
    Monitor = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', Monitor, process, Pid, _Reason} -> ok
    after 5000 -> error({still_alive, Pid})
    end.

restarted(Name, Old) ->
    restarted(Name, Old, 100).

restarted(Name, Old, 0) ->
    error({not_restarted, Name, Old});
restarted(Name, Old, Tries) ->
    case registered_as(Name) of
        Pid when is_pid(Pid), Pid =/= Old ->
            Pid;
        _ ->
            timer:sleep(20),
            restarted(Name, Old, Tries - 1)
    end.

registered_as(Name) when is_atom(Name) -> whereis(Name);
registered_as(Name) -> seki_registry:whereis_name(Name).
