-module(seki_name_sup_tests).

-include_lib("eunit/include/eunit.hrl").

-export([log/2, kills_until_gone/2, restarted_after_a_kill/2, supervised/2]).

-define(KINDS, [seki_breaker, seki_bulkhead, seki_adaptive, seki_shed, seki_health]).
-define(HANDLER, seki_name_sup_tests).
-define(PARENT, seki_name_sup_tests_parent).

isolation_test_() ->
    {foreach,
        fun() ->
            {ok, _} = application:ensure_all_started(seki),
            ok
        end,
        fun(_) -> application:stop(seki) end, [
            fun a_crash_loop_takes_its_own_name_only/0,
            fun a_name_that_gave_up_is_an_unknown_name/0,
            fun an_open_breaker_that_gave_up_is_created_open/0,
            fun crash_loops_in_many_names_leave_their_supervisor/0,
            fun a_deleted_name_takes_its_supervisor_along/0,
            fun the_names_a_supervisor_holds_are_found_with_their_processes/0,
            fun stopping_seki_is_quick_and_silent/0
        ]}.

a_name_tolerates_three_restarts_in_ten_seconds_test() ->
    ?assertEqual(
        {ok,
            {
                #{
                    strategy => one_for_one,
                    intensity => 3,
                    period => 10,
                    auto_shutdown => any_significant
                },
                []
            }},
        seki_name_sup:init([])
    ).

the_process_is_started_under_a_supervisor_of_its_own_test() ->
    Trapping = process_flag(trap_exit, true),
    try
        {ok, Supervisor, Process} = seki_name_sup:start_link(process(a_name, #{})),
        ?assertEqual(
            [{a_name, Process, worker, [seki_bulkhead]}], supervisor:which_children(Supervisor)
        ),
        ?assertEqual({ok, Process}, seki_name_sup:process(Supervisor)),
        ?assertEqual(Process, whereis(a_name)),
        ok = proc_lib:stop(Process),
        ?assertEqual(not_running, seki_name_sup:process(Supervisor)),
        ok = proc_lib:stop(Supervisor),
        ?assertEqual(gone, seki_name_sup:process(Supervisor)),
        receive
            {'EXIT', Supervisor, Reason} -> ?assertEqual(normal, Reason)
        end
    after
        process_flag(trap_exit, Trapping)
    end.

a_process_that_does_not_start_leaves_nothing_behind_test() ->
    Trapping = process_flag(trap_exit, true),
    try
        Links = links(),
        ?assertEqual(
            {error,
                {not_started,
                    {invalid_options,
                        {child, undefined, a_name, {seki_bulkhead, start_link, [a_name, []]},
                            transient, false, 5000, worker, [seki_bulkhead]}}}},
            seki_name_sup:start_link(process(a_name, []))
        ),
        ?assertEqual(Links, links()),
        ?assertEqual(
            [],
            [
                Supervisor
             || Supervisor <:- processes(),
                proc_lib:translate_initial_call(Supervisor) =:= {supervisor, seki_name_sup, 1}
            ]
        ),
        ?assertEqual(
            nothing,
            receive
                Message -> Message
            after 0 -> nothing
            end
        )
    after
        process_flag(trap_exit, Trapping)
    end.

what_the_supervisor_above_answers_test_() ->
    Gone = spawn(fun() -> ok end),
    Monitor = monitor(process, Gone),
    receive
        {'DOWN', Monitor, process, Gone, _} -> ok
    end,
    [
        ?_assertEqual({ok, self()}, started_after([{ok, Gone, self()}])),
        ?_assertEqual(
            {ok, self()}, started_after([{error, {already_started, Gone}}, {ok, Gone, self()}])
        ),
        ?_assertEqual(
            {error, {already_started, self()}},
            started_after([
                {error, {already_started, Gone}},
                {error, {{not_started, {already_started, self()}}, a_child}}
            ])
        ),
        ?_assertEqual(
            {error, {a_reason, a_process}},
            started_after([{error, {{not_started, {a_reason, a_process}}, a_child}}])
        ),
        ?_assertEqual({error, a_reason}, started_after([{error, a_reason}])),
        ?_assertEqual(
            {error, {{'EXIT', a_reason}, a_child}},
            started_after([{error, {{'EXIT', a_reason}, a_child}}])
        )
    ].

%% Stands where a supervisor would and answers each `start_child` in turn
%% with what it was given.
started_after(Answers) ->
    Self = self(),
    Process = process(a_name, #{}),
    Parent = spawn_link(fun() ->
        true = register(?PARENT, self()),
        Self ! registered,
        [
            receive
                {'$gen_call', From, {start_child, Spec}} ->
                    #{
                        id := a_name,
                        start := {seki_name_sup, start_link, [Process]},
                        restart := temporary,
                        shutdown := infinity,
                        type := supervisor
                    } = Spec,
                    gen_server:reply(From, Answer)
            end
         || Answer <:- Answers
        ]
    end),
    Monitor = monitor(process, Parent),
    receive
        registered -> ok
    end,
    Started = seki_name_sup:start(?PARENT, Process),
    receive
        {'DOWN', Monitor, process, Parent, normal} -> Started
    end.

links() ->
    {links, Links} = process_info(self(), links),
    lists:sort(Links).

process(Name, Opts) ->
    #{
        id => Name,
        start => {seki_bulkhead, start_link, [Name, Opts]},
        restart => transient,
        shutdown => 5000
    }.

a_crash_loop_takes_its_own_name_only() ->
    [
        begin
            Parent = whereis(parent(Kind)),
            Others = [{Other, with_state(Kind, Other)} || Other <:- others(Kind)],
            States = [state(Kind, Other) || {Other, _Process} <:- Others],
            {ok, _} = new(Kind, Looping),
            ?assertEqual(4, kills_until_gone(parent(Kind), Looping)),
            ?assertEqual(Parent, whereis(parent(Kind))),
            [?assertEqual(Process, registered(Other)) || {Other, Process} <:- Others],
            ?assertEqual(States, [state(Kind, Other) || {Other, _Process} <:- Others]),
            ?assertEqual(undefined, registered(Looping)),
            ?assertEqual({error, not_found}, delete(Kind, Looping)),
            {ok, Again} = new(Kind, Looping),
            ?assertEqual(Again, registered(Looping)),
            ?assertEqual({Kind, init, 1}, proc_lib:translate_initial_call(Again)),
            [?assertEqual(ok, delete(Kind, Name)) || Name <:- [Looping | others(Kind)]]
        end
     || Kind <:- ?KINDS, Looping <:- [seki_name_sup_tests_looping, {Kind, ~"looping"}]
    ].

a_name_that_gave_up_is_an_unknown_name() ->
    [
        begin
            {ok, _} = new(Kind, Gone),
            ?assertEqual(4, kills_until_gone(parent(Kind), Gone)),
            ?assertEqual(unknown(Kind), calls(Kind, Gone)),
            ?assertEqual(unknown(Kind), calls(Kind, {Kind, ~"never created"}))
        end
     || Kind <:- ?KINDS, Gone <:- [seki_name_sup_tests_gone, {Kind, ~"gone"}]
    ].

an_open_breaker_that_gave_up_is_created_open() ->
    [
        begin
            Opts = #{window_size => 5, wait_duration => 60000},
            {ok, _} = seki:new_breaker(Name, Opts),
            [{ok, error} = seki:call(Name, fun() -> error end) || _ <:- lists:seq(1, 5)],
            ?assertEqual(open, seki:state(Name)),
            ?assertEqual(4, kills_until_gone(seki_breaker_sup, Name)),
            ?assertExit({noproc, _}, seki:call(Name, fun() -> ok end)),
            {ok, _} = seki:new_breaker(Name, Opts),
            ?assertEqual(open, seki:state(Name)),
            ?assertEqual({error, circuit_open}, seki:call(Name, fun() -> ok end)),
            ?assertEqual(ok, seki:delete_breaker(Name)),
            {ok, _} = seki:new_breaker(Name, Opts),
            ?assertEqual(closed, seki:state(Name)),
            ?assertEqual(ok, seki:delete_breaker(Name))
        end
     || Name <:- [seki_name_sup_tests_open, {breaker, ~"open"}]
    ].

crash_loops_in_many_names_leave_their_supervisor() ->
    Parent = whereis(seki_process_sup),
    {ok, Kept} = seki:new_bulkhead({bulkhead, ~"kept"}, #{max_concurrent => 1}),
    ok = seki_bulkhead:acquire({bulkhead, ~"kept"}),
    [
        begin
            {ok, _} = seki:new_bulkhead({bulkhead, Number}, #{}),
            ?assertEqual(4, kills_until_gone(seki_process_sup, {bulkhead, Number}))
        end
     || Number <:- lists:seq(1, 6)
    ],
    ?assertEqual(Parent, whereis(seki_process_sup)),
    ?assertEqual(Kept, registered({bulkhead, ~"kept"})),
    ?assertEqual({error, bulkhead_full}, seki_bulkhead:acquire({bulkhead, ~"kept"})),
    ?assertMatch([{{bulkhead, ~"kept"}, _, _, _}], supervisor:which_children(seki_process_sup)).

a_deleted_name_takes_its_supervisor_along() ->
    [
        begin
            {ok, Process} = new(Kind, Name),
            Supervisor = supervisor_of(parent(Kind), Name),
            ?assertEqual({ok, Process}, seki_name_sup:process(Supervisor)),
            Monitors = [{monitor(process, Pid), Pid} || Pid <:- [Process, Supervisor]],
            ?assertEqual(ok, delete(Kind, Name)),
            [
                receive
                    {'DOWN', Monitor, process, Pid, Reason} -> ?assertEqual(shutdown, Reason)
                end
             || {Monitor, Pid} <:- Monitors
            ],
            ?assertEqual([], supervisor:which_children(parent(Kind)))
        end
     || Kind <:- ?KINDS, Name <:- [seki_name_sup_tests_deleted, {Kind, ~"deleted"}]
    ].

the_names_a_supervisor_holds_are_found_with_their_processes() ->
    Breakers = [
        {Name, element(2, {ok, _} = seki:new_breaker(Name, #{}))}
     || Name <:- [seki_name_sup_tests_held, {breaker, 1}, ~"breaker 2"]
    ],
    Others = [
        {Name, element(2, {ok, _} = new(Kind, Name))}
     || Kind <:- ?KINDS -- [seki_breaker], Name <:- [Kind, {Kind, 1}, [Kind, 2]]
    ],
    {ok, Stopped} = seki:new_shed({shed, ~"stopped"}, #{}),
    ok = proc_lib:stop(Stopped),
    ?assertEqual(
        lists:sort([Named || {Name, _Process} = Named <:- Breakers, not is_atom(Name)]),
        lists:sort(seki_registry:named_children(seki_breaker_sup))
    ),
    ?assertEqual(
        lists:sort([Named || {Name, _Process} = Named <:- Others, not is_atom(Name)]),
        lists:sort(seki_registry:named_children(seki_process_sup))
    ),
    ?assertEqual([], seki_registry:named_children(seki_name_sup_tests_not_running)).

stopping_seki_is_quick_and_silent() ->
    [{ok, _} = new(Kind, {Kind, Number}) || Kind <:- ?KINDS, Number <:- lists:seq(1, 100)],
    ok = seki:new_limiter({limiter, ~"gossiping"}, #{
        algorithm => gcra, limit => 1, window => 1000, backend => seki_backend_pg
    }),
    ok = logger:add_handler(?HANDLER, ?MODULE, #{level => warning, config => #{pid => self()}}),
    try
        {Micros, ok} = timer:tc(fun() -> application:stop(seki) end),
        ?assert(Micros < 5_000_000)
    after
        ok = logger:remove_handler(?HANDLER)
    end,
    ?assertEqual(
        nothing,
        receive
            {logged, _Level, _Report} = Logged -> Logged
        after 0 -> nothing
        end
    ).

log(#{level := Level, msg := {report, Report}}, #{config := #{pid := Pid}}) ->
    Pid ! {logged, Level, Report},
    ok;
log(_Event, _Config) ->
    ok.

others(Kind) ->
    [seki_name_sup_tests_other, {Kind, ~"other"}].

with_state(seki_breaker, Name) ->
    {ok, Breaker} = seki:new_breaker(Name, #{window_size => 5, wait_duration => 60000}),
    [{ok, error} = seki:call(Name, fun() -> error end) || _ <:- lists:seq(1, 5)],
    Breaker;
with_state(seki_bulkhead, Name) ->
    {ok, Bulkhead} = seki:new_bulkhead(Name, #{max_concurrent => 3}),
    ok = seki_bulkhead:acquire(Name),
    Bulkhead;
with_state(seki_adaptive, Name) ->
    {ok, Adaptive} = seki:new_adaptive(Name, #{}),
    ok = seki_adaptive:acquire(Name),
    Adaptive;
with_state(seki_shed, Name) ->
    {ok, Shed} = seki:new_shed(Name, #{}),
    ok = seki_shed:admit(Name),
    Shed;
with_state(seki_health, Name) ->
    {ok, Health} = seki:new_health(Name, #{vm_checks => false}),
    ok = seki_health:register_check(Name, database, fun() -> {degraded, #{slow => true}} end),
    Health.

state(seki_breaker, Name) -> seki:state(Name);
state(seki_bulkhead, Name) -> seki_bulkhead:status(Name);
state(seki_adaptive, Name) -> seki_adaptive:status(Name);
state(seki_shed, Name) -> seki_shed:status(Name);
state(seki_health, Name) -> seki_health:check(Name).

unknown(seki_breaker) -> [noproc, noproc, ok];
unknown(seki_bulkhead) -> [noproc, noproc, ok];
unknown(seki_adaptive) -> [noproc, noproc, ok];
unknown(seki_shed) -> [noproc, noproc, ok];
unknown(seki_health) -> [noproc, noproc, {error, unhealthy}].

calls(seki_breaker, Name) ->
    [
        outcome(fun() -> seki:call(Name, fun() -> ok end) end),
        outcome(fun() -> seki:state(Name) end),
        outcome(fun() -> seki:reset_breaker(Name) end)
    ];
calls(seki_bulkhead, Name) ->
    [
        outcome(fun() -> seki_bulkhead:call(Name, fun() -> ok end) end),
        outcome(fun() -> seki_bulkhead:status(Name) end),
        outcome(fun() -> seki_bulkhead:release(Name) end)
    ];
calls(seki_adaptive, Name) ->
    [
        outcome(fun() -> seki_adaptive:call(Name, fun() -> ok end) end),
        outcome(fun() -> seki_adaptive:status(Name) end),
        outcome(fun() -> seki_adaptive:release(Name, ok) end)
    ];
calls(seki_shed, Name) ->
    [
        outcome(fun() -> seki_shed:admit(Name) end),
        outcome(fun() -> seki_shed:status(Name) end),
        outcome(fun() -> seki_shed:complete(Name, 1) end)
    ];
calls(seki_health, Name) ->
    [
        outcome(fun() -> seki_health:check(Name) end),
        outcome(fun() -> seki_health:readiness(Name) end),
        outcome(fun() -> seki_health:liveness(Name) end)
    ].

outcome(Call) ->
    try
        Call()
    catch
        exit:{noproc, _} -> noproc
    end.

%% Kills the process of a name each time it has been restarted, and counts
%% the kills it takes before the name is gone.
-spec kills_until_gone(atom(), term()) -> non_neg_integer().
kills_until_gone(Parent, Id) ->
    kills_until_gone(Parent, Id, 0).

kills_until_gone(Parent, Id, Kills) when Kills < 12 ->
    case supervised(Parent, Id) of
        gone ->
            Kills;
        {ok, _Process} ->
            _ = restarted_after_a_kill(Parent, Id),
            kills_until_gone(Parent, Id, Kills + 1)
    end.

-spec restarted_after_a_kill(atom(), term()) -> {ok, pid()} | gone.
restarted_after_a_kill(Parent, Id) ->
    {ok, Process} = supervised(Parent, Id),
    Monitor = monitor(process, Process),
    exit(Process, kill),
    receive
        {'DOWN', Monitor, process, Process, killed} -> ok
    end,
    settled(Parent, Id, Process).

%% A supervisor answers in turn, so asking it again is how to wait for it to
%% have seen its child go.
settled(Parent, Id, Killed) ->
    case supervised(Parent, Id) of
        gone -> gone;
        {ok, Process} when Process =/= Killed -> {ok, Process};
        _Unsettled -> settled(Parent, Id, Killed)
    end.

-spec supervisor_of(atom(), term()) -> pid().
supervisor_of(Parent, Id) ->
    case lists:keyfind(Id, 1, supervisor:which_children(Parent)) of
        {Id, Supervisor, supervisor, [seki_name_sup]} when is_pid(Supervisor) -> Supervisor
    end.

-spec supervised(atom(), term()) -> {ok, pid()} | gone | unsettled.
supervised(Parent, Id) ->
    case lists:keyfind(Id, 1, supervisor:which_children(Parent)) of
        false ->
            gone;
        {Id, Supervisor, supervisor, [seki_name_sup]} when is_pid(Supervisor) ->
            case seki_name_sup:process(Supervisor) of
                {ok, Process} -> {ok, Process};
                _NotRunning -> unsettled
            end
    end.

new(Kind, Name) ->
    new(Kind, Name, #{}).

new(seki_breaker, Name, Opts) -> seki:new_breaker(Name, Opts);
new(seki_bulkhead, Name, Opts) -> seki:new_bulkhead(Name, Opts);
new(seki_adaptive, Name, Opts) -> seki:new_adaptive(Name, Opts);
new(seki_shed, Name, Opts) -> seki:new_shed(Name, Opts);
new(seki_health, Name, Opts) -> seki:new_health(Name, Opts).

delete(seki_breaker, Name) -> seki:delete_breaker(Name);
delete(seki_bulkhead, Name) -> seki:delete_bulkhead(Name);
delete(seki_adaptive, Name) -> seki:delete_adaptive(Name);
delete(seki_shed, Name) -> seki:delete_shed(Name);
delete(seki_health, Name) -> seki:delete_health(Name).

parent(seki_breaker) -> seki_breaker_sup;
parent(_Kind) -> seki_process_sup.

registered(Name) when is_atom(Name) -> whereis(Name);
registered(Name) -> seki_registry:whereis_name(Name).
