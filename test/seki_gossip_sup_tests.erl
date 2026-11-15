-module(seki_gossip_sup_tests).

-include_lib("eunit/include/eunit.hrl").

-define(OPTS, #{
    algorithm => gcra,
    limit => 5,
    window => 60000,
    backend => seki_backend_pg,
    backend_opts => #{gossip_interval => 3600000}
}).

gossip_test_() ->
    {foreach,
        fun() ->
            {ok, _} = application:ensure_all_started(seki),
            ok
        end,
        fun(_) -> application:stop(seki) end, [
            fun a_gossip_process_that_dies_costs_no_limiter/0,
            fun a_gossip_crash_loop_ends_the_gossip_of_one_limiter/0,
            fun gossip_ends_with_the_owner_of_its_table/0,
            fun gossip_ends_with_the_limiter_registry/0,
            fun gossip_ends_with_its_limiter/0,
            fun a_gossip_process_is_given_five_seconds_to_stop/0,
            fun no_gossip_is_linked_while_the_supervisor_is_down/0
        ]}.

a_backend_started_without_seki_is_stopped_while_seki_runs_test() ->
    _ = application:stop(seki),
    {ok, State} = seki_backend_pg:init(#{gossip_interval => 3600000}),
    {Tab, Gossip} = started(State),
    {ok, _} = application:ensure_all_started(seki),
    try
        ?assertEqual([], supervisor:which_children(seki_gossip_sup)),
        ?assertEqual(ok, seki_backend_pg:terminate(State)),
        ?assertNot(is_process_alive(Gossip)),
        ?assertEqual(undefined, ets:info(Tab, id))
    after
        ok = application:stop(seki),
        ok = gen_server:stop(seki_pg)
    end.

without_seki_gossip_is_linked_to_its_caller_test() ->
    _ = application:stop(seki),
    {ok, State} = seki_backend_pg:init(#{gossip_interval => 3600000}),
    {Tab, Gossip} = started(State),
    try
        {links, Links} = process_info(self(), links),
        ?assert(lists:member(Gossip, Links)),
        ?assertEqual([Gossip], pg:get_members(seki_pg, {seki_limiters, seki_pg_data})),
        ?assertEqual(ok, seki_backend_pg:terminate(State)),
        ?assertNot(is_process_alive(Gossip)),
        ?assertEqual(undefined, ets:info(Tab, id))
    after
        ok = gen_server:stop(seki_pg)
    end.

a_gossip_process_that_dies_costs_no_limiter() ->
    Registry = whereis(seki_limiter_registry),
    ok = seki:new_limiter({api, ~"tenant"}, ?OPTS),
    ok = seki:new_limiter(local, maps:without([backend, backend_opts], ?OPTS)),
    [{allow, _} = seki:check(Name, user) || Name <:- [{api, ~"tenant"}, local], _ <:- [1, 2, 3]],
    {Tab, First} = gossip({api, ~"tenant"}),
    {ok, Second} = seki_name_sup_tests:restarted_after_a_kill(seki_gossip_sup, Tab),
    ?assertNotEqual(First, Second),
    ?assertEqual(Registry, whereis(seki_limiter_registry)),
    ?assertEqual([Second], pg:get_members(seki_pg, {seki_limiter, {api, ~"tenant"}})),
    [
        begin
            ?assertMatch({allow, #{remaining := 1}}, seki:check(Name, user)),
            ?assertMatch({allow, #{remaining := 0}}, seki:check(Name, user)),
            ?assertMatch({deny, _}, seki:check(Name, user))
        end
     || Name <:- [{api, ~"tenant"}, local]
    ],
    gen_server:cast(Second, {seki_gossip, 2, gcra, [{from_a_peer, 1000}]}),
    _ = sys:get_state(Second),
    ?assertMatch([{from_a_peer, _}], ets:lookup(Tab, from_a_peer)).

a_gossip_crash_loop_ends_the_gossip_of_one_limiter() ->
    Registry = whereis(seki_limiter_registry),
    ok = seki:new_limiter(looping, ?OPTS),
    ok = seki:new_limiter(kept, ?OPTS),
    {Looping, _} = gossip(looping),
    {Kept, Gossip} = gossip(kept),
    {allow, _} = seki:check(looping, user),
    ?assertEqual(4, seki_name_sup_tests:kills_until_gone(seki_gossip_sup, Looping)),
    ?assertEqual(Registry, whereis(seki_limiter_registry)),
    ?assertEqual({ok, Gossip}, seki_name_sup_tests:supervised(seki_gossip_sup, Kept)),
    ?assertEqual([], pg:get_members(seki_pg, {seki_limiter, looping})),
    ?assertMatch({allow, #{remaining := 3}}, seki:check(looping, user)),
    ?assertEqual(ok, seki:delete_limiter(looping)),
    ?assertEqual(undefined, ets:info(Looping, id)),
    ?assertError({limiter_not_found, looping}, seki:check(looping, user)),
    ?assertMatch({allow, _}, seki:check(kept, user)).

gossip_ends_with_the_owner_of_its_table() ->
    Self = self(),
    Owner = spawn(fun() ->
        Self ! {started, seki_backend_pg:init(#{gossip_interval => 3600000})},
        receive
            stop -> ok
        end
    end),
    {ok, State} =
        receive
            {started, Started} -> Started
        end,
    {Tab, Gossip} = started(State),
    ?assertEqual({ok, Gossip}, seki_name_sup_tests:supervised(seki_gossip_sup, Tab)),
    {links, Links} = process_info(Owner, links),
    ?assertNot(lists:member(Gossip, Links)),
    Monitor = monitor(process, Gossip),
    Owner ! stop,
    receive
        {'DOWN', Monitor, process, Gossip, Reason} -> ?assertEqual(normal, Reason)
    end,
    ?assertEqual(gone, gone(Tab)).

gossip_ends_with_the_limiter_registry() ->
    ok = seki:new_limiter(lost, ?OPTS),
    {Tab, Gossip} = gossip(lost),
    Registry = running(seki_limiter_registry),
    Monitors = [{monitor(process, Pid), Pid} || Pid <:- [Registry, Gossip]],
    exit(Registry, kill),
    ?assertEqual(
        [killed, normal],
        [
            receive
                {'DOWN', Monitor, process, Pid, Reason} -> Reason
            end
         || {Monitor, Pid} <:- Monitors
        ]
    ),
    ?assertEqual(gone, gone(Tab)).

gossip_ends_with_its_limiter() ->
    ok = seki:new_limiter(deleted, ?OPTS),
    {Tab, Gossip} = gossip(deleted),
    Monitor = monitor(process, Gossip),
    ?assertEqual(ok, seki:delete_limiter(deleted)),
    receive
        {'DOWN', Monitor, process, Gossip, Reason} -> ?assertEqual(shutdown, Reason)
    end,
    ?assertEqual([], supervisor:which_children(seki_gossip_sup)),
    ?assertEqual(undefined, ets:info(Tab, id)).

a_gossip_process_is_given_five_seconds_to_stop() ->
    ok = seki:new_limiter(specified, ?OPTS),
    {Tab, Gossip} = gossip(specified),
    [Supervisor] = [
        Pid
     || {Id, Pid, supervisor, _Modules} <:- supervisor:which_children(seki_gossip_sup),
        Id =:= Tab,
        is_pid(Pid)
    ],
    ?assertEqual([{Tab, Gossip, worker, [seki_pg_gossip]}], supervisor:which_children(Supervisor)),
    {ok, Spec} = supervisor:get_childspec(Supervisor, Tab),
    ?assertEqual(
        #{restart => transient, shutdown => 5000, significant => true, type => worker},
        maps:with([restart, shutdown, significant, type], Spec)
    ).

no_gossip_is_linked_while_the_supervisor_is_down() ->
    Registry = running(seki_limiter_registry),
    Supervisor = running(seki_gossip_sup),
    Links = process_info(Registry, links),
    Opts = ?OPTS,
    ok = sys:suspend(seki_sup),
    try
        Monitor = monitor(process, Supervisor),
        exit(Supervisor, kill),
        receive
            {'DOWN', Monitor, process, Supervisor, killed} -> ok
        end,
        ?assertMatch(
            {error, {backend_failed, {noproc, _}}},
            seki:new_limiter(unheld, Opts#{
                backend_opts => #{
                    table_name => seki_gossip_sup_tests_unheld, gossip_interval => 3600000
                }
            })
        ),
        ?assertEqual(Links, process_info(Registry, links)),
        ?assertEqual(
            [],
            [Tab || Tab <:- ets:all(), ets:info(Tab, name) =:= seki_gossip_sup_tests_unheld]
        )
    after
        ok = sys:resume(seki_sup)
    end,
    ?assertEqual(Registry, whereis(seki_limiter_registry)),
    ?assertError({limiter_not_found, unheld}, seki:check(unheld, user)).

gossip(Limiter) ->
    {gcra, seki_backend_pg, State, _Config} = seki_limiter_registry:lookup(Limiter),
    {Tab, _Started} = started(State),
    {ok, Gossip} = seki_name_sup_tests:supervised(seki_gossip_sup, Tab),
    {Tab, Gossip}.

%% The table of a backend and the gossip process it was started with.
-spec started(term()) -> {ets:table(), pid()}.
started({state, Tab, Gossip, _Scope}) when is_reference(Tab), is_pid(Gossip) ->
    {Tab, Gossip}.

-spec running(atom()) -> pid().
running(Name) ->
    live(whereis(Name)).

-spec live(term()) -> pid().
live(Process) when is_pid(Process) -> Process.

%% The supervisor of a gossip process that ended goes with it, a moment
%% after: the supervisor above answers in turn, so it is asked again.
gone(Tab) ->
    case seki_name_sup_tests:supervised(seki_gossip_sup, Tab) of
        gone -> gone;
        _NotYet -> gone(Tab)
    end.
