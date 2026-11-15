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
            fun names_outlive_a_restart_of_the_keeper/0,
            fun only_the_registry_writes_the_table/0,
            fun only_the_registry_is_given_the_table/0,
            fun the_registry_restarts_over_any_row/0,
            fun only_a_local_process_is_registered/0,
            fun an_unknown_message_leaves_the_registry_running/0,
            fun a_breaker_is_named_by_a_term/0,
            fun a_bulkhead_is_named_by_a_term/0,
            fun a_load_shedder_is_named_by_a_term/0,
            fun an_adaptive_limiter_is_named_by_a_term/0,
            fun a_health_checker_is_named_by_a_term/0,
            fun a_limiter_is_named_by_a_term/0,
            fun a_distributed_limiter_named_by_a_term_has_its_own_group/0,
            fun a_named_process_restarts_under_its_name/0,
            fun a_call_reaches_a_process_by_its_pid/0,
            fun a_cast_reaches_a_process_by_its_pid/0,
            fun a_pid_is_not_a_name/0,
            fun a_tuple_is_a_name_and_not_a_node/0,
            fun naming_by_terms_creates_no_atoms/0,
            fun nothing_is_registered_while_seki_is_stopped/0,
            fun an_unknown_name_lets_nothing_through/0,
            fun a_stopped_seki_lets_nothing_through/0
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

names_outlive_a_restart_of_the_keeper() ->
    {ok, Breaker} = seki:new_breaker(?NAME, #{}),
    Keeper = whereis(seki_registry_keeper),
    stopped(Keeper),
    _ = restarted(seki_registry_keeper, Keeper),
    _ = sys:get_state(seki_registry),
    Registry = whereis(seki_registry),
    stopped(Registry),
    _ = restarted(seki_registry, Registry),
    ?assertEqual(Breaker, seki_registry:whereis_name(?NAME)),
    ?assertEqual(closed, seki:state(?NAME)).

only_the_registry_writes_the_table() ->
    {ok, Breaker} = seki:new_breaker(?NAME, #{}),
    ?assertEqual(protected, ets:info(seki_registry, protection)),
    ?assertEqual(whereis(seki_registry), ets:info(seki_registry, owner)),
    ?assertError(badarg, ets:insert(seki_registry, {?NAME, self(), make_ref()})),
    ?assertError(badarg, ets:delete(seki_registry, ?NAME)),
    ?assertError(badarg, ets:delete_all_objects(seki_registry)),
    ?assertEqual(Breaker, seki_registry:whereis_name(?NAME)).

only_the_registry_is_given_the_table() ->
    Registry = whereis(seki_registry),
    ?assertEqual({error, not_the_registry}, seki_registry_keeper:claim()),
    ok = sys:suspend(seki_registry),
    ?assertEqual({error, not_the_registry}, seki_registry_keeper:claim()),
    ok = sys:resume(seki_registry),
    ?assertEqual(Registry, ets:info(seki_registry, owner)).

the_registry_restarts_over_any_row() ->
    {ok, Breaker} = seki:new_breaker(?NAME, #{}),
    Gone = idle(),
    stopped(Gone),
    Rows = [
        {junk},
        {{junk, 1}, not_a_pid, make_ref()},
        {{junk, 2}, remote_pid(), make_ref()},
        {{junk, 3}, Gone, make_ref()},
        {{junk, 4}, self()},
        {{junk, 5}, self(), not_a_monitor, extra}
    ],
    sys:replace_state(seki_registry, fun(Names) ->
        true = ets:insert(seki_registry, Rows),
        Names
    end),
    Supervisor = whereis(seki_sup),
    [
        begin
            Registry = whereis(seki_registry),
            stopped(Registry),
            _ = sys:get_state(restarted(seki_registry, Registry))
        end
     || _Round <:- lists:seq(1, 3)
    ],
    ?assertEqual(Supervisor, whereis(seki_sup)),
    ?assertMatch([{?NAME, Breaker, _}], ets:tab2list(seki_registry)),
    ?assertEqual(closed, seki:state(?NAME)),
    [
        ?assertEqual(undefined, seki_registry:whereis_name(Name))
     || Name <:- [junk | [{junk, Number} || Number <:- lists:seq(1, 5)]]
    ].

only_a_local_process_is_registered() ->
    Remote = remote_pid(),
    ?assertError(function_clause, seki_registry:register_name(?NAME, Remote)),
    Registry = whereis(seki_registry),
    ?assertEqual(
        {error, unknown_request}, gen_server:call(seki_registry, {register, ?NAME, Remote})
    ),
    ?assertEqual(
        {error, unknown_request}, gen_server:call(seki_registry, {register, ?NAME, not_a_pid})
    ),
    ?assertEqual(undefined, seki_registry:whereis_name(?NAME)),
    ?assertEqual(Registry, whereis(seki_registry)).

an_unknown_message_leaves_the_registry_running() ->
    Registry = whereis(seki_registry),
    Keeper = whereis(seki_registry_keeper),
    ?assertEqual(yes, seki_registry:register_name(?NAME, self())),
    [
        begin
            Server ! Message,
            gen_server:cast(Server, Message),
            _ = gen_server:call(Server, Message)
        end
     || Server <:- [seki_registry, seki_registry_keeper],
        Message <:- [
            unknown,
            {'DOWN', make_ref(), process, self(), normal},
            {'DOWN', not_a_monitor, process, not_a_pid, normal},
            {'ETS-TRANSFER', seki_registry, self(), seki_registry},
            {unregister, {'_', '$1'}},
            {register, ?NAME, not_a_pid},
            keeper_restarted,
            claim
        ]
    ],
    ?assertEqual(Registry, whereis(seki_registry)),
    ?assertEqual(Keeper, whereis(seki_registry_keeper)),
    ?assertEqual(self(), seki_registry:whereis_name(?NAME)).

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

a_call_reaches_a_process_by_its_pid() ->
    ?assertEqual(self(), seki_registry:server(self())),
    {ok, Breaker} = seki:new_breaker({breaker, pid}, #{}),
    ?assertEqual(closed, seki:state(Breaker)),
    ?assertEqual({ok, 42}, seki:call(Breaker, fun() -> 42 end)),
    {ok, Bulkhead} = seki:new_bulkhead(seki_registry_tests_pid, #{max_concurrent => 1}),
    ?assertMatch(#{current := 0, max := 1}, seki_bulkhead:status(Bulkhead)),
    ?assertEqual({ok, done}, seki_bulkhead:call(Bulkhead, fun() -> done end)),
    {ok, Shed} = seki:new_shed({shed, pid}, #{}),
    ?assertEqual(ok, seki_shed:admit(Shed)),
    ?assertMatch(#{in_flight := 1}, seki_shed:status(Shed)),
    {ok, Adaptive} = seki:new_adaptive({adaptive, pid}, #{}),
    ?assertEqual({ok, hello}, seki_adaptive:call(Adaptive, fun() -> hello end)),
    {ok, Health} = seki:new_health({health, pid}, #{vm_checks => false}),
    ?assertEqual(ok, seki_health:readiness(Health)).

a_cast_reaches_a_process_by_its_pid() ->
    {ok, Breaker} = seki:new_breaker({breaker, pid}, #{window_size => 5, wait_duration => 60000}),
    [seki:call({breaker, pid}, fun() -> {error, down} end) || _ <:- lists:seq(1, 5)],
    ?assertEqual(open, seki:state({breaker, pid})),
    ?assertEqual(ok, seki:reset_breaker(Breaker)),
    ?assertEqual(closed, seki:state({breaker, pid})),
    {ok, Bulkhead} = seki:new_bulkhead({bulkhead, pid}, #{max_concurrent => 1}),
    ?assertEqual(ok, seki_bulkhead:acquire({bulkhead, pid})),
    ?assertEqual(ok, seki_bulkhead:release(Bulkhead)),
    ?assertMatch(#{current := 0}, seki_bulkhead:status({bulkhead, pid})),
    {ok, Shed} = seki:new_shed({shed, pid}, #{}),
    ?assertEqual(ok, seki_shed:admit({shed, pid})),
    ?assertEqual(ok, seki_shed:complete(Shed, 1)),
    ?assertMatch(#{in_flight := 0}, seki_shed:status({shed, pid})),
    {ok, Adaptive} = seki:new_adaptive({adaptive, pid}, #{}),
    ?assertEqual(ok, seki_adaptive:acquire({adaptive, pid})),
    ?assertEqual(ok, seki_adaptive:release(Adaptive, ok)),
    ?assertMatch(#{in_flight := 0}, seki_adaptive:status({adaptive, pid})).

a_pid_is_not_a_name() ->
    Invalid = {error, {invalid_name, self()}},
    ?assertEqual(Invalid, seki:new_breaker(self(), #{})),
    ?assertEqual(Invalid, seki:new_bulkhead(self(), #{})),
    ?assertEqual(Invalid, seki:new_shed(self(), #{})),
    ?assertEqual(Invalid, seki:new_adaptive(self(), #{})),
    ?assertEqual(Invalid, seki:new_health(self(), #{})),
    ?assertEqual(
        Invalid,
        seki:new_limiter(self(), #{algorithm => token_bucket, limit => 1, window => 1000})
    ),
    ?assertError(function_clause, seki_registry:registration(self())),
    ?assertEqual([], supervisor:which_children(seki_breaker_sup)),
    ?assertEqual([], supervisor:which_children(seki_process_sup)),
    ?assertEqual([], ets:tab2list(seki_registry)),
    ?assertError({limiter_not_found, _}, seki:check(self(), user)).

a_tuple_is_a_name_and_not_a_node() ->
    {ok, _} = seki:new_breaker(seki_registry_tests_local, #{}),
    ?assertExit({noproc, _}, seki:state({seki_registry_tests_local, node()})),
    {ok, Named} = seki:new_breaker({seki_registry_tests_local, node()}, #{}),
    ?assertNotEqual(Named, whereis(seki_registry_tests_local)),
    ?assertEqual(closed, seki:state({seki_registry_tests_local, node()})).

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

%% As with an atom: a call exits with `noproc`, a cast is dropped.
nothing_is_registered_while_seki_is_stopped() ->
    {ok, _} = seki:new_breaker(?NAME, #{}),
    ok = application:stop(seki),
    ?assertEqual(undefined, seki_registry:whereis_name(?NAME)),
    ?assertExit({noproc, _}, seki:state(?NAME)),
    ?assertExit({noproc, _}, seki:state(seki_registry_tests_no_breaker)),
    ?assertEqual(ok, seki:reset_breaker(?NAME)).

an_unknown_name_lets_nothing_through() ->
    [nothing_gets_through(Name) || Name <:- [seki_registry_tests_unknown, {unknown, 1}]],
    [
        ?assertError({limiter_not_found, Name}, Check())
     || Name <:- [seki_registry_tests_unknown, {unknown, 1}], Check <:- limiter_checks(Name)
    ].

a_stopped_seki_lets_nothing_through() ->
    Opts = #{algorithm => token_bucket, limit => 1, window => 1000},
    ok = seki:new_limiter(seki_registry_tests_limiter, Opts),
    ok = seki:new_limiter({limiter, 1}, Opts),
    ok = application:stop(seki),
    [nothing_gets_through(Name) || Name <:- [seki_registry_tests_unknown, {unknown, 1}]],
    [
        ?assertError(badarg, Check())
     || Name <:- [seki_registry_tests_limiter, {limiter, 1}], Check <:- limiter_checks(Name)
    ].

nothing_gets_through(Name) ->
    Never = fun() -> error(must_not_run) end,
    [
        ?assertExit({noproc, _}, Call())
     || Call <:- [
            fun() -> seki:call(Name, Never) end,
            fun() -> seki:call(Name, Never, #{}) end,
            fun() -> seki:state(Name) end,
            fun() -> seki_bulkhead:call(Name, Never) end,
            fun() -> seki_bulkhead:acquire(Name) end,
            fun() -> seki_bulkhead:status(Name) end,
            fun() -> seki_shed:admit(Name) end,
            fun() -> seki_shed:status(Name) end,
            fun() -> seki_adaptive:call(Name, Never) end,
            fun() -> seki_adaptive:acquire(Name) end,
            fun() -> seki_adaptive:status(Name) end,
            fun() -> seki_health:check(Name) end,
            fun() -> seki_health:readiness(Name) end
        ]
    ],
    ?assertEqual({error, unhealthy}, seki_health:liveness(Name)),
    ?assertEqual(ok, seki:reset_breaker(Name)),
    ?assertEqual(ok, seki_bulkhead:release(Name)),
    ?assertEqual(ok, seki_shed:complete(Name, 1)),
    ?assertEqual(ok, seki_adaptive:release(Name, ok)).

limiter_checks(Name) ->
    Never = fun() -> error(must_not_run) end,
    [
        fun() -> seki:check(Name, user) end,
        fun() -> seki:check(Name, user, 1) end,
        fun() -> seki:inspect(Name, user) end,
        fun() -> seki:reset(Name, user) end,
        fun() -> seki:execute(seki_registry_tests_unknown, Name, Never) end
    ].

remote_pid() ->
    Node = ~"elsewhere@nohost",
    binary_to_term(<<131, 88, 119, (byte_size(Node)), Node/binary, 1:32, 0:32, 1:32>>).

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
