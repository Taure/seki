-module(seki_create_tests).

-include_lib("eunit/include/eunit.hrl").

%% What `seki:new_*` and `seki:delete_*` return for each kind of named
%% process, whatever stands between the caller and the process.

-define(KINDS, [seki_breaker, seki_bulkhead, seki_adaptive, seki_shed, seki_health]).
-define(SHARING_A_SUPERVISOR, [seki_bulkhead, seki_adaptive, seki_shed, seki_health]).

create_test_() ->
    {foreach,
        fun() ->
            {ok, _} = application:ensure_all_started(seki),
            ok
        end,
        fun(_) -> application:stop(seki) end, [
            fun the_named_process_is_returned/0,
            fun a_pid_is_no_name/0,
            fun options_are_checked_before_anything_starts/0,
            fun a_name_is_taken_once/0,
            fun a_name_is_taken_across_the_kinds_that_share_a_supervisor/0,
            fun a_name_is_taken_across_breakers_and_the_rest/0,
            fun an_atom_registered_elsewhere_is_taken/0,
            fun a_process_that_stopped_is_still_present/0,
            fun a_deleted_name_can_be_created_again/0,
            fun an_unknown_name_is_not_found/0,
            fun a_start_that_fails_names_the_process/0,
            fun creating_at_once_starts_one_process/0
        ]}.

nothing_is_created_while_seki_is_stopped_test() ->
    _ = application:stop(seki),
    [
        begin
            Parent = parent(Kind),
            ?assertExit(
                {noproc, {gen_server, call, [Parent, {start_child, _}, infinity]}},
                new(Kind, stopped, #{})
            ),
            ?assertExit(
                {noproc, {gen_server, call, [Parent, {terminate_child, stopped}, infinity]}},
                delete(Kind, stopped)
            )
        end
     || Kind <:- ?KINDS
    ].

the_named_process_is_returned() ->
    [
        begin
            {ok, Process} = new(Kind, Name, #{}),
            ?assertEqual(Process, registered(Name)),
            ?assertEqual({Kind, init, 1}, proc_lib:translate_initial_call(Process)),
            ?assertEqual(ok, delete(Kind, Name))
        end
     || Kind <:- ?KINDS, Name <:- [seki_create_tests_named, {Kind, ~"named"}]
    ].

a_pid_is_no_name() ->
    [?assertEqual({error, {invalid_name, self()}}, new(Kind, self(), #{})) || Kind <:- ?KINDS].

options_are_checked_before_anything_starts() ->
    [
        begin
            ?assertEqual({error, invalid_options}, new(Kind, Name, [])),
            ?assertEqual({error, {invalid_option, Key}}, new(Kind, Name, #{Key => 0})),
            ?assertEqual(undefined, registered(Name)),
            ?assertEqual({error, not_found}, delete(Kind, Name))
        end
     || {Kind, Key} <:- [
            {seki_breaker, window_size},
            {seki_bulkhead, max_concurrent},
            {seki_adaptive, min_limit},
            {seki_shed, target},
            {seki_health, check_interval}
        ],
        Name <:- [seki_create_tests_refused, {Kind, ~"refused"}]
    ].

a_name_is_taken_once() ->
    [
        begin
            {ok, Process} = new(Kind, Name, #{}),
            ?assertEqual({error, {already_started, Process}}, new(Kind, Name, #{})),
            ?assertEqual(Process, registered(Name)),
            ?assertEqual(ok, delete(Kind, Name))
        end
     || Kind <:- ?KINDS, Name <:- [seki_create_tests_taken, {Kind, ~"taken"}]
    ].

a_name_is_taken_across_the_kinds_that_share_a_supervisor() ->
    [
        begin
            {ok, Process} = new(First, Name, #{}),
            ?assertEqual({error, {already_started, Process}}, new(Second, Name, #{})),
            ?assertEqual({First, init, 1}, proc_lib:translate_initial_call(registered(Name))),
            ?assertEqual(ok, delete(Second, Name))
        end
     || First <:- ?SHARING_A_SUPERVISOR,
        Second <:- ?SHARING_A_SUPERVISOR,
        First =/= Second,
        Name <:- [seki_create_tests_shared, {shared, ~"name"}]
    ].

a_name_is_taken_across_breakers_and_the_rest() ->
    [
        begin
            {ok, Process} = new(First, Name, #{}),
            ?assertEqual({error, {already_started, Process}}, new(Second, Name, #{})),
            ?assertEqual({error, not_found}, delete(Second, Name)),
            ?assertEqual(Process, registered(Name)),
            ?assertEqual(ok, delete(First, Name))
        end
     || {First, Second} <:- [{seki_breaker, seki_bulkhead}, {seki_shed, seki_breaker}],
        Name <:- [seki_create_tests_apart, {apart, ~"name"}]
    ].

an_atom_registered_elsewhere_is_taken() ->
    true = register(seki_create_tests_elsewhere, self()),
    try
        [
            begin
                ?assertEqual(
                    {error, {already_started, self()}},
                    new(Kind, seki_create_tests_elsewhere, #{})
                ),
                ?assertEqual({error, not_found}, delete(Kind, seki_create_tests_elsewhere))
            end
         || Kind <:- ?KINDS
        ]
    after
        true = unregister(seki_create_tests_elsewhere)
    end.

a_process_that_stopped_is_still_present() ->
    [
        begin
            {ok, Process} = new(Kind, Name, #{}),
            ok = proc_lib:stop(Process),
            ?assertEqual({error, already_present}, new(Kind, Name, #{})),
            ?assertEqual(undefined, registered(Name)),
            ?assertEqual(ok, delete(Kind, Name)),
            {ok, Again} = new(Kind, Name, #{}),
            ?assertEqual(Again, registered(Name)),
            ?assertEqual(ok, delete(Kind, Name))
        end
     || Kind <:- ?KINDS, Name <:- [seki_create_tests_stopped, {Kind, ~"stopped"}]
    ].

a_deleted_name_can_be_created_again() ->
    [
        begin
            {ok, First} = new(Kind, Name, #{}),
            Monitor = monitor(process, First),
            ?assertEqual(ok, delete(Kind, Name)),
            receive
                {'DOWN', Monitor, process, First, Reason} -> ?assertEqual(shutdown, Reason)
            end,
            ?assertEqual({error, not_found}, delete(Kind, Name)),
            {ok, Second} = new(Kind, Name, #{}),
            ?assertNotEqual(First, Second),
            ?assertEqual(Second, registered(Name)),
            ?assertEqual(ok, delete(Kind, Name))
        end
     || Kind <:- ?KINDS, Name <:- [seki_create_tests_again, {Kind, ~"again"}]
    ].

an_unknown_name_is_not_found() ->
    [
        ?assertEqual({error, not_found}, delete(Kind, Name))
     || Kind <:- ?KINDS, Name <:- [seki_create_tests_unknown, {Kind, ~"unknown"}]
    ].

%% A process named by a term registers while it starts, and gives up when
%% the registry stays down. What comes back names the process that did not
%% start, as its supervisor describes it.
a_start_that_fails_names_the_process() ->
    Registry = whereis(seki_registry),
    ok = sys:suspend(seki_registry_sup),
    try
        Monitor = monitor(process, Registry),
        exit(Registry, kill),
        receive
            {'DOWN', Monitor, process, Registry, killed} -> ok
        end,
        [
            begin
                Name = {Kind, ~"fails"},
                {error, {Reason, Child}} = new(Kind, Name, #{}),
                {noproc, {gen_server, call, [seki_registry, {register, Name, Process}]}} = Reason,
                ?assert(is_pid(Process)),
                ?assertNot(is_process_alive(Process)),
                ?assertEqual(
                    {child, undefined, Name, {Kind, start_link, [Name, #{}]}, transient, false,
                        5000, worker, [Kind]},
                    Child
                )
            end
         || Kind <:- ?KINDS
        ]
    after
        ok = sys:resume(seki_registry_sup)
    end,
    [?assertEqual({error, not_found}, delete(Kind, {Kind, ~"fails"})) || Kind <:- ?KINDS].

creating_at_once_starts_one_process() ->
    [
        begin
            Self = self(),
            Creators = [
                spawn_link(fun() -> Self ! {created, self(), new(Kind, Name, #{})} end)
             || _ <:- lists:seq(1, 20)
            ],
            Results = [
                receive
                    {created, Creator, Result} -> Result
                end
             || Creator <:- Creators
            ],
            [Process] = [Created || {ok, Created} <- Results],
            ?assertEqual(
                lists:duplicate(19, {error, {already_started, Process}}),
                Results -- [{ok, Process}]
            ),
            ?assertEqual(Process, registered(Name)),
            ?assertEqual(ok, delete(Kind, Name))
        end
     || Kind <:- ?KINDS, Name <:- [seki_create_tests_at_once, {Kind, ~"at once"}]
    ].

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
