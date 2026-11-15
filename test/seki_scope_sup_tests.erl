-module(seki_scope_sup_tests).

-include_lib("eunit/include/eunit.hrl").

scope_test_() ->
    {foreach,
        fun() ->
            {ok, _} = application:ensure_all_started(seki),
            ok
        end,
        fun(_) -> application:stop(seki) end, [
            fun seki_starts_the_scope_it_uses/0,
            fun a_scope_that_is_running_is_used_as_it_is/0,
            fun a_name_registered_for_something_else_is_refused/0,
            fun gossip_joins_again_when_its_scope_is_restarted/0,
            fun callers_starting_a_scope_at_once_share_it/0,
            fun a_name_taken_while_its_scope_starts_is_refused/0,
            fun nothing_starts_outside_the_tree_while_the_supervisor_is_down/0,
            fun a_scope_crash_loop_costs_no_limiter/0,
            fun gossip_waits_for_a_scope_whose_name_is_taken/0
        ]}.

without_seki_a_scope_is_started_unsupervised_test() ->
    _ = application:stop(seki),
    ?assertEqual(undefined, whereis(seki_scope_sup_tests_scope)),
    ?assertEqual(ok, seki_scope_sup:ensure(seki_scope_sup_tests_scope)),
    ?assertEqual(ok, seki_scope_sup:ensure(seki_scope_sup_tests_scope)),
    ?assertEqual([], pg:which_groups(seki_scope_sup_tests_scope)),
    {links, Links} = process_info(self(), links),
    ?assertNot(lists:member(whereis(seki_scope_sup_tests_scope), Links)),
    ok = gen_server:stop(seki_scope_sup_tests_scope).

seki_starts_the_scope_it_uses() ->
    ?assertEqual([], supervisor:which_children(seki_scope_sup)),
    ?assertEqual(undefined, whereis(seki_pg)),
    ok = seki:new_limiter(supervised, opts(#{})),
    Scope = running(seki_pg),
    ?assertEqual([{seki_pg, Scope, worker, [pg]}], supervisor:which_children(seki_scope_sup)),
    ok = seki:new_limiter(another, opts(#{})),
    ?assertEqual([{seki_pg, Scope, worker, [pg]}], supervisor:which_children(seki_scope_sup)),
    ok = seki:new_limiter(elsewhere, opts(#{scope => seki_scope_sup_tests_own})),
    ?assertEqual(
        [seki_pg, seki_scope_sup_tests_own],
        lists:sort([Id || {Id, _, _, _} <:- supervisor:which_children(seki_scope_sup)])
    ),
    Monitor = monitor(process, Scope),
    ok = application:stop(seki),
    receive
        {'DOWN', Monitor, process, Scope, Reason} -> ?assertEqual(shutdown, Reason)
    end,
    ?assertEqual(undefined, whereis(seki_scope_sup_tests_own)).

a_scope_that_is_running_is_used_as_it_is() ->
    {ok, Scope} = pg:start_link(seki_scope_sup_tests_running),
    try
        ?assertEqual(ok, seki_scope_sup:ensure(seki_scope_sup_tests_running)),
        ok = seki:new_limiter(shared, opts(#{scope => seki_scope_sup_tests_running})),
        ?assertEqual([], supervisor:which_children(seki_scope_sup)),
        ?assertEqual(Scope, whereis(seki_scope_sup_tests_running)),
        ?assertMatch(
            [_Gossip], pg:get_members(seki_scope_sup_tests_running, {seki_limiter, shared})
        ),
        ?assertEqual(ok, seki:delete_limiter(shared))
    after
        true = unlink(Scope),
        ok = gen_server:stop(Scope)
    end.

a_name_registered_for_something_else_is_refused() ->
    Registry = whereis(seki_limiter_registry),
    Tables = length(ets:all()),
    [Port | _] = erlang:ports(),
    true = register(seki_scope_sup_tests_port, Port),
    try
        [
            begin
                ?assertEqual({error, not_a_scope}, seki_scope_sup:ensure(Scope)),
                ?assertEqual(
                    {error, {invalid_option, scope}}, seki_backend_pg:init(#{scope => Scope})
                ),
                ?assertEqual(
                    {error, {backend_failed, {invalid_option, scope}}},
                    seki:new_limiter(refused, opts(#{scope => Scope}))
                )
            end
         || Scope <:- [seki_sup, seki_registry, seki_limiter_registry, seki_scope_sup_tests_port]
        ]
    after
        true = unregister(seki_scope_sup_tests_port)
    end,
    ?assertError({limiter_not_found, refused}, seki:check(refused, user)),
    ?assertEqual(Tables, length(ets:all())),
    ?assertEqual([], supervisor:which_children(seki_scope_sup)),
    ?assertEqual(Registry, whereis(seki_limiter_registry)).

gossip_joins_again_when_its_scope_is_restarted() ->
    ok = seki:new_limiter(rejoining, opts(#{gossip_interval => 3600000})),
    {gcra, seki_backend_pg, State, _Config} = seki_limiter_registry:lookup(rejoining),
    Gossip = gossip(State),
    ?assertEqual([Gossip], pg:get_members(seki_pg, {seki_limiter, rejoining})),
    Joined = sys:get_state(Gossip),
    Scope = running(seki_pg),
    Monitor = monitor(process, Scope),
    exit(Scope, kill),
    receive
        {'DOWN', Monitor, process, Scope, killed} -> ok
    end,
    ok = joined_again(Gossip, Joined),
    ?assertNotEqual(Scope, whereis(seki_pg)),
    ?assertEqual([Gossip], pg:get_members(seki_pg, {seki_limiter, rejoining})),
    ?assertEqual(State, element(3, seki_limiter_registry:lookup(rejoining))),
    ?assertMatch({allow, _}, seki:check(rejoining, user)).

callers_starting_a_scope_at_once_share_it() ->
    Scope = seki_scope_sup_tests_at_once,
    Self = self(),
    ok = sys:suspend(seki_scope_sup),
    Callers = [
        spawn_link(fun() -> Self ! {ensured, self(), seki_scope_sup:ensure(Scope)} end)
     || _ <:- [1, 2, 3]
    ],
    ok = queued(seki_scope_sup, 3),
    ok = sys:resume(seki_scope_sup),
    ?assertEqual(
        [ok, ok, ok],
        [
            receive
                {ensured, Caller, Result} -> Result
            end
         || Caller <:- Callers
        ]
    ),
    ?assertEqual(
        [{Scope, whereis(Scope), worker, [pg]}], supervisor:which_children(seki_scope_sup)
    ).

a_name_taken_while_its_scope_starts_is_refused() ->
    Scope = seki_scope_sup_tests_taken,
    Self = self(),
    ok = sys:suspend(seki_scope_sup),
    Caller = spawn_link(fun() -> Self ! {ensured, self(), seki_scope_sup:ensure(Scope)} end),
    ok = queued(seki_scope_sup, 1),
    true = register(Scope, self()),
    try
        ok = sys:resume(seki_scope_sup),
        ?assertEqual(
            {error, not_a_scope},
            receive
                {ensured, Caller, Result} -> Result
            end
        )
    after
        true = unregister(Scope)
    end,
    ?assertEqual([], supervisor:which_children(seki_scope_sup)).

nothing_starts_outside_the_tree_while_the_supervisor_is_down() ->
    Scope = seki_scope_sup_tests_down,
    Supervisor = running(seki_scope_sup),
    ok = sys:suspend(seki_sup),
    try
        ok = killed(Supervisor),
        ?assertEqual({error, not_a_scope}, seki_scope_sup:ensure(Scope)),
        ?assertEqual(undefined, whereis(Scope))
    after
        ok = sys:resume(seki_sup)
    end,
    Restarted = restarted(seki_scope_sup, Supervisor),
    ?assertEqual(ok, seki_scope_sup:ensure(Scope)),
    ?assertEqual([{Scope, whereis(Scope), worker, [pg]}], supervisor:which_children(Restarted)).

%% The supervisor of the scopes gives up on the eleventh crash of a scope in
%% a minute and is started again without it. The gossip process starts the
%% scope it needs again, and the limiter never notices.
a_scope_crash_loop_costs_no_limiter() ->
    Registry = whereis(seki_limiter_registry),
    ok = seki:new_limiter(looping, opts(#{gossip_interval => 3600000})),
    {gcra, seki_backend_pg, State, _Config} = seki_limiter_registry:lookup(looping),
    Gossip = gossip(State),
    {allow, _} = seki:check(looping, user),
    Supervisor = running(seki_scope_sup),
    ?assertEqual(11, kills_until_down(seki_pg, monitor(process, Supervisor), 0)),
    ?assertNotEqual(Supervisor, restarted(seki_scope_sup, Supervisor)),
    ok = member_again(seki_pg, {seki_limiter, looping}, Gossip),
    ?assertEqual(Registry, whereis(seki_limiter_registry)),
    ?assertEqual(State, element(3, seki_limiter_registry:lookup(looping))),
    ?assertMatch({allow, #{remaining := 3}}, seki:check(looping, user)).

kills_until_down(Scope, Supervisor, Kills) ->
    ok = killed(restarted(Scope, undefined)),
    receive
        {'DOWN', Supervisor, process, _Pid, _Reason} -> Kills + 1
    after 0 ->
        case restarted_or_down(Scope, Supervisor) of
            restarted -> kills_until_down(Scope, Supervisor, Kills + 1);
            down -> Kills + 1
        end
    end.

restarted_or_down(Scope, Supervisor) ->
    receive
        {'DOWN', Supervisor, process, _Pid, _Reason} -> down
    after 0 ->
        case whereis(Scope) of
            undefined ->
                erlang:yield(),
                restarted_or_down(Scope, Supervisor);
            _Restarted ->
                restarted
        end
    end.

member_again(Scope, Group, Member) ->
    try pg:get_members(Scope, Group) of
        [Member] ->
            ok;
        _NotYet ->
            erlang:yield(),
            member_again(Scope, Group, Member)
    catch
        error:badarg ->
            erlang:yield(),
            member_again(Scope, Group, Member)
    end.

%% The gossip process is held still while its scope is replaced by something
%% that is not one, so it finds the name taken when it looks.
gossip_waits_for_a_scope_whose_name_is_taken() ->
    Scope = seki_scope_sup_tests_held,
    {ok, First} = pg:start(Scope),
    ok = seki:new_limiter(waiting, opts(#{scope => Scope, gossip_interval => 3600000})),
    {gcra, seki_backend_pg, State, _Config} = seki_limiter_registry:lookup(waiting),
    Gossip = gossip(State),
    ?assertEqual([Gossip], pg:get_members(Scope, {seki_limiter, waiting})),
    ok = sys:suspend(Gossip),
    ok = killed(First),
    true = register(Scope, self()),
    ok = sys:resume(Gossip),
    ?assertEqual(undefined, element(8, sys:get_state(Gossip))),
    true = unregister(Scope),
    {ok, Second} = pg:start(Scope),
    try
        ok = member_again(Scope, {seki_limiter, waiting}, Gossip),
        ?assert(is_reference(element(8, sys:get_state(Gossip)))),
        ?assertMatch({allow, _}, seki:check(waiting, user)),
        ?assertEqual(ok, seki:delete_limiter(waiting))
    after
        ok = gen_server:stop(Second)
    end.

%% The gossip process answers in turn, so asking it again is how to wait for
%% it to have heard of its scope. Its state changes when it has joined again.
joined_again(Gossip, Joined) ->
    case sys:get_state(Gossip) of
        Joined -> joined_again(Gossip, Joined);
        Waiting when element(8, Waiting) =:= undefined -> joined_again(Gossip, Joined);
        _JoinedAgain -> ok
    end.

opts(BackendOpts) ->
    #{
        algorithm => gcra,
        limit => 5,
        window => 60000,
        backend => seki_backend_pg,
        backend_opts => BackendOpts
    }.

%% A supervisor that is suspended leaves what it is sent in its queue.
queued(Name, Messages) ->
    case process_info(running(Name), message_queue_len) of
        {message_queue_len, Length} when Length >= Messages ->
            ok;
        _NotYet ->
            erlang:yield(),
            queued(Name, Messages)
    end.

killed(Pid) ->
    Monitor = monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', Monitor, process, Pid, killed} -> ok
    end.

-spec restarted(atom(), pid() | undefined) -> pid().
restarted(Name, Old) ->
    case whereis(Name) of
        Pid when is_pid(Pid), Pid =/= Old ->
            Pid;
        _NotYet ->
            erlang:yield(),
            restarted(Name, Old)
    end.

-spec gossip(term()) -> pid().
gossip({state, _Tab, Gossip, _Scope}) when is_pid(Gossip) -> Gossip.

-spec running(atom()) -> pid().
running(Name) ->
    live(whereis(Name)).

-spec live(term()) -> pid().
live(Process) when is_pid(Process) -> Process.
