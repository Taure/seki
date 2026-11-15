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
            fun gossip_joins_again_when_its_scope_is_restarted/0
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

-spec gossip(term()) -> pid().
gossip({state, _Tab, Gossip, _Scope}) when is_pid(Gossip) -> Gossip.

-spec running(atom()) -> pid().
running(Name) ->
    case whereis(Name) of
        Process when is_pid(Process) -> Process
    end.
