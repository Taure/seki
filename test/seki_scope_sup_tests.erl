-module(seki_scope_sup_tests).

-behaviour(supervisor).

-include_lib("eunit/include/eunit.hrl").

-export([init/1]).

scope_test_() ->
    {foreach,
        fun() ->
            {ok, _} = application:ensure_all_started(seki),
            ok
        end,
        fun(_) -> application:stop(seki) end, [
            fun seki_starts_the_scope_it_uses/0,
            fun a_scope_that_is_running_is_used_as_it_is/0,
            fun a_scope_of_either_release_is_one/0,
            fun a_process_started_like_a_scope_without_its_table_is_refused/0,
            fun a_scope_that_is_still_starting_is_waited_for/0,
            fun a_name_registered_for_something_else_is_refused/0,
            fun gossip_joins_again_when_its_scope_is_restarted/0,
            fun callers_starting_a_scope_at_once_share_it/0,
            fun a_name_taken_while_its_scope_starts_is_refused/0,
            fun nothing_starts_outside_the_tree_while_the_supervisor_is_down/0,
            fun a_scope_crash_loop_costs_no_limiter/0,
            fun gossip_waits_for_a_scope_whose_name_is_taken/0,
            fun a_scope_of_the_application_is_left_to_its_supervisor/0,
            fun a_scope_of_the_application_that_is_killed_is_left_to_its_supervisor/0,
            fun a_scope_seki_holds_is_one_it_starts_again/0,
            fun gossip_started_again_leaves_a_scope_of_the_application_down/0
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

%% `pg` runs a scope as itself up to OTP 28 and as a `data_publisher` from
%% OTP 29. A process started as either, holding the table a scope is named
%% by, is a scope on whichever release the test runs.
a_scope_of_either_release_is_one() ->
    [
        begin
            Scope = started_as(StartedAs, [table]),
            ?assertEqual(ok, seki_scope_sup:ensure(seki_scope_sup_tests_release)),
            ?assertEqual(ok, seki_scope_sup:running(seki_scope_sup_tests_release)),
            ?assertNot(seki_scope_sup:held(seki_scope_sup_tests_release)),
            ok = killed(Scope)
        end
     || StartedAs <:- [{pg, init, 1}, {data_publisher, init, 1}]
    ].

%% Being started the way a scope is does not make a process one: a store
%% that is a `data_publisher` of something else, or a process that only says
%% so, has no table named after it.
a_process_started_like_a_scope_without_its_table_is_refused() ->
    Registry = whereis(seki_limiter_registry),
    [
        begin
            NotAScope = started_as(StartedAs, []),
            ?assertEqual({error, not_a_scope}, seki_scope_sup:ensure(seki_scope_sup_tests_release)),
            ?assertEqual(
                {error, {backend_failed, {invalid_option, scope}}},
                seki:new_limiter(refused, opts(#{scope => seki_scope_sup_tests_release}))
            ),
            ok = killed(NotAScope)
        end
     || StartedAs <:- [{pg, init, 1}, {data_publisher, init, 1}]
    ],
    Other = spawn(fun() ->
        _ = ets:new(seki_scope_sup_tests_release, [named_table]),
        receive
            stop -> ok
        end
    end),
    Fake = started_as({pg, init, 1}, []),
    ok = until(fun() -> ets:info(seki_scope_sup_tests_release, owner) =:= Other end),
    ?assertEqual({error, not_a_scope}, seki_scope_sup:ensure(seki_scope_sup_tests_release)),
    ok = killed(Fake),
    ok = killed(Other),
    ?assertEqual(ok, seki:new_limiter(plain, maps:without([backend, backend_opts], opts(#{})))),
    ?assertEqual(Registry, whereis(seki_limiter_registry)),
    ?assertEqual([], supervisor:which_children(seki_scope_sup)).

%% A scope that has registered its name and not yet made its table is still
%% starting, and is waited for.
a_scope_that_is_still_starting_is_waited_for() ->
    Self = self(),
    Scope = spawn(fun() ->
        put('$initial_call', {pg, init, 1}),
        true = register(seki_scope_sup_tests_release, self()),
        Self ! {registered, self()},
        receive
            make_table -> ok
        end,
        _ = ets:new(seki_scope_sup_tests_release, [named_table]),
        receive
            stop -> ok
        end
    end),
    receive
        {registered, Scope} -> ok
    end,
    Caller = spawn_link(fun() ->
        Self ! {ensured, self(), seki_scope_sup:ensure(seki_scope_sup_tests_release)}
    end),
    ok = until(fun() -> process_info(Caller, status) =:= {status, waiting} end),
    Scope ! make_table,
    ?assertEqual(
        ok,
        receive
            {ensured, Caller, Result} -> Result
        end
    ),
    ok = killed(Scope).

started_as(StartedAs, Holding) ->
    Self = self(),
    Process = spawn(fun() ->
        put('$initial_call', StartedAs),
        _ = [ets:new(seki_scope_sup_tests_release, [named_table]) || table <:- Holding],
        true = register(seki_scope_sup_tests_release, self()),
        Self ! {started, self()},
        receive
            stop -> ok
        end
    end),
    receive
        {started, Process} -> Process
    end.

until(Condition) ->
    case Condition() of
        true ->
            ok;
        false ->
            erlang:yield(),
            until(Condition)
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
    ?assertEqual(undefined, scope_monitor(sys:get_state(Gossip))),
    true = unregister(Scope),
    {ok, Second} = pg:start(Scope),
    try
        ok = member_again(Scope, {seki_limiter, waiting}, Gossip),
        ?assert(is_reference(scope_monitor(sys:get_state(Gossip)))),
        ?assertMatch({allow, _}, seki:check(waiting, user)),
        ?assertEqual(ok, seki:delete_limiter(waiting))
    after
        ok = gen_server:stop(Second)
    end.

%% The application holds the scope under a supervisor of its own. When the
%% scope is stopped, seki leaves the name free, so the supervisor can start
%% the scope again, and the gossip process joins the new one.
a_scope_of_the_application_is_left_to_its_supervisor() ->
    Scope = seki_scope_sup_tests_theirs,
    Supervisor = application_supervisor(Scope),
    try
        ok = seki:new_limiter(theirs, opts(#{scope => Scope, gossip_interval => 3600000})),
        {gcra, seki_backend_pg, State, _Config} = seki_limiter_registry:lookup(theirs),
        Gossip = gossip(State),
        ?assertNot(seki_scope_sup:held(Scope)),
        ?assertNot(own_scope(sys:get_state(Gossip))),
        ok = supervisor:terminate_child(Supervisor, Scope),
        ?assertEqual(undefined, scope_monitor(sys:get_state(Gossip))),
        receive
        after 250 -> ok
        end,
        ?assertEqual(undefined, whereis(Scope)),
        ?assertEqual([], supervisor:which_children(seki_scope_sup)),
        ?assertMatch({allow, _}, seki:check(theirs, user)),
        ?assertMatch({ok, _Restarted}, supervisor:restart_child(Supervisor, Scope)),
        ok = member_again(Scope, {seki_limiter, theirs}, Gossip),
        ?assertNot(own_scope(sys:get_state(Gossip))),
        ?assertEqual([], supervisor:which_children(seki_scope_sup)),
        ?assertEqual(ok, seki:delete_limiter(theirs))
    after
        stopped(Supervisor)
    end.

%% Killed with many limiters on it, the scope is started again by the
%% supervisor that holds it and by nothing else, however many gossip
%% processes saw it go.
a_scope_of_the_application_that_is_killed_is_left_to_its_supervisor() ->
    Scope = seki_scope_sup_tests_theirs,
    Supervisor = application_supervisor(Scope),
    Names = [{theirs, N} || N <:- lists:seq(1, 25)],
    try
        [
            ok = seki:new_limiter(Name, opts(#{scope => Scope, gossip_interval => 3600000}))
         || Name <:- Names
        ],
        [
            begin
                Running = running(Scope),
                ok = killed(Running),
                Restarted = restarted(Scope, Running),
                ?assertEqual(
                    [{Scope, Restarted, worker, [pg]}], supervisor:which_children(Supervisor)
                )
            end
         || _ <:- lists:seq(1, 5)
        ],
        ?assertEqual([], supervisor:which_children(seki_scope_sup)),
        [
            begin
                {gcra, seki_backend_pg, State, _Config} = seki_limiter_registry:lookup(Name),
                ok = member_again(Scope, {seki_limiter, Name}, gossip(State))
            end
         || Name <:- Names
        ],
        [?assertEqual(ok, seki:delete_limiter(Name)) || Name <:- Names]
    after
        stopped(Supervisor)
    end.

a_scope_seki_holds_is_one_it_starts_again() ->
    ok = seki:new_limiter(ours, opts(#{gossip_interval => 3600000})),
    {gcra, seki_backend_pg, State, _Config} = seki_limiter_registry:lookup(ours),
    ?assert(seki_scope_sup:held(seki_pg)),
    ?assertEqual(ok, seki_scope_sup:running(seki_pg)),
    ?assert(own_scope(sys:get_state(gossip(State)))),
    ?assertNot(seki_scope_sup:held(seki_scope_sup_tests_theirs)),
    ?assertEqual({error, not_a_scope}, seki_scope_sup:running(seki_scope_sup_tests_theirs)),
    ?assertEqual(undefined, whereis(seki_scope_sup_tests_theirs)).

%% The gossip process dies while the scope of the application is stopped.
%% Started again, it still knows the scope is not seki's and waits for it.
gossip_started_again_leaves_a_scope_of_the_application_down() ->
    Scope = seki_scope_sup_tests_theirs,
    Supervisor = application_supervisor(Scope),
    try
        ok = seki:new_limiter(theirs, opts(#{scope => Scope, gossip_interval => 3600000})),
        {gcra, seki_backend_pg, State, _Config} = seki_limiter_registry:lookup(theirs),
        Gossip = gossip(State),
        ok = supervisor:terminate_child(Supervisor, Scope),
        ok = killed(Gossip),
        Restarted = gossip_again(Gossip),
        ?assertEqual(undefined, scope_monitor(sys:get_state(Restarted))),
        ?assertNot(own_scope(sys:get_state(Restarted))),
        ?assertEqual(undefined, whereis(Scope)),
        ?assertEqual([], supervisor:which_children(seki_scope_sup)),
        ?assertMatch({ok, _Scope}, supervisor:restart_child(Supervisor, Scope)),
        ok = member_again(Scope, {seki_limiter, theirs}, Restarted),
        ?assertMatch({allow, _}, seki:check(theirs, user)),
        ?assertEqual(ok, seki:delete_limiter(theirs))
    after
        stopped(Supervisor)
    end.

gossip_again(Old) ->
    Running = [
        Pid
     || {_Name, NameSup, _Type, _Modules} <:- supervisor:which_children(seki_gossip_sup),
        is_pid(NameSup),
        {_Id, Pid, _ChildType, _ChildModules} <:- supervisor:which_children(NameSup),
        is_pid(Pid),
        Pid =/= Old
    ],
    case Running of
        [Restarted] ->
            Restarted;
        [] ->
            erlang:yield(),
            gossip_again(Old)
    end.

application_supervisor(Scope) ->
    {ok, Supervisor} = supervisor:start_link(?MODULE, [Scope]),
    Supervisor.

stopped(Supervisor) ->
    true = unlink(Supervisor),
    Monitor = monitor(process, Supervisor),
    exit(Supervisor, shutdown),
    receive
        {'DOWN', Monitor, process, Supervisor, _Reason} -> ok
    end.

init([Scope]) ->
    {ok,
        {#{strategy => one_for_one, intensity => 100, period => 1}, [
            #{id => Scope, start => {pg, start_link, [Scope]}}
        ]}}.

-spec scope_monitor(term()) -> term().
scope_monitor(State) when is_tuple(State) -> element(8, State).

-spec own_scope(term()) -> term().
own_scope(State) when is_tuple(State) -> element(10, State).

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
