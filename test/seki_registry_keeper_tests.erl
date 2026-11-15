-module(seki_registry_keeper_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TAB, seki_registry).
-define(ROW, {a_name, self(), make_ref()}).

keeper_test_() ->
    [
        fun a_new_keeper_holds_a_protected_table/0,
        fun only_the_registry_is_given_the_table/0,
        fun the_table_is_given_once/0,
        fun the_table_returns_when_the_registry_dies/0,
        fun a_keeper_started_over_a_held_table_tells_the_registry/0,
        fun a_claim_makes_a_table_that_is_gone/0,
        fun an_unknown_message_leaves_the_keeper_running/0
    ].

a_new_keeper_holds_a_protected_table() ->
    Keeper = started(),
    ?assertEqual(Keeper, whereis(seki_registry_keeper)),
    ?assertEqual(Keeper, ets:info(?TAB, owner)),
    ?assertEqual(Keeper, ets:info(?TAB, heir)),
    ?assertEqual(protected, ets:info(?TAB, protection)),
    ?assertEqual(set, ets:info(?TAB, type)),
    ?assertEqual(true, ets:info(?TAB, named_table)),
    ?assertEqual(true, ets:info(?TAB, read_concurrency)),
    stopped(Keeper).

only_the_registry_is_given_the_table() ->
    Keeper = started(),
    ?assertEqual({error, not_the_registry}, seki_registry_keeper:claim()),
    ?assertEqual(Keeper, ets:info(?TAB, owner)),
    ?assertError(badarg, ets:insert(?TAB, ?ROW)),
    ok = become_registry(),
    ?assertEqual(ok, seki_registry_keeper:claim()),
    ?assertEqual(self(), ets:info(?TAB, owner)),
    ?assertEqual(Keeper, ets:info(?TAB, heir)),
    ?assertEqual(
        given,
        receive
            {'ETS-TRANSFER', ?TAB, Keeper, ?TAB} -> given
        after 1000 -> not_given
        end
    ),
    stopped(Keeper).

the_table_is_given_once() ->
    Keeper = started(),
    ok = become_registry(),
    ok = seki_registry_keeper:claim(),
    ?assertEqual({error, not_the_owner}, seki_registry_keeper:claim()),
    ?assertEqual(self(), ets:info(?TAB, owner)),
    stopped(Keeper).

the_table_returns_when_the_registry_dies() ->
    Keeper = started(),
    {Registry, Monitor} = spawn_monitor(fun() ->
        true = register(seki_registry, self()),
        ok = seki_registry_keeper:claim(),
        true = ets:insert(?TAB, ?ROW)
    end),
    receive
        {'DOWN', Monitor, process, Registry, Reason} -> ?assertEqual(normal, Reason)
    end,
    ok = wait_until(fun() -> ets:info(?TAB, owner) =:= Keeper end),
    ?assertMatch([{a_name, Registry, _}], ets:lookup(?TAB, a_name)),
    ok = become_registry(),
    ?assertEqual(ok, seki_registry_keeper:claim()),
    ?assertEqual(self(), ets:info(?TAB, owner)),
    ?assertMatch([{a_name, Registry, _}], ets:lookup(?TAB, a_name)),
    stopped(Keeper).

a_keeper_started_over_a_held_table_tells_the_registry() ->
    First = started(),
    ok = become_registry(),
    ok = seki_registry_keeper:claim(),
    true = ets:insert(?TAB, ?ROW),
    ok = gen_server:stop(First),
    {ok, Second} = seki_registry_keeper:start_link(),
    ?assertEqual(
        told,
        receive
            {'$gen_cast', keeper_restarted} -> told
        after 1000 -> not_told
        end
    ),
    ?assertEqual(self(), ets:info(?TAB, owner)),
    ?assertMatch([{a_name, _, _}], ets:lookup(?TAB, a_name)),
    stopped(Second).

a_claim_makes_a_table_that_is_gone() ->
    Keeper = started(),
    ok = become_registry(),
    ok = seki_registry_keeper:claim(),
    true = ets:delete(?TAB),
    ?assertEqual(ok, seki_registry_keeper:claim()),
    ?assertEqual(self(), ets:info(?TAB, owner)),
    ?assertEqual(Keeper, ets:info(?TAB, heir)),
    ?assertEqual(protected, ets:info(?TAB, protection)),
    stopped(Keeper).

an_unknown_message_leaves_the_keeper_running() ->
    Keeper = started(),
    ?assertEqual({error, unknown_request}, gen_server:call(Keeper, unknown)),
    ok = gen_server:cast(Keeper, unknown),
    Keeper ! unknown,
    ?assertEqual([], sys:get_state(Keeper)),
    ?assertEqual(Keeper, ets:info(?TAB, owner)),
    stopped(Keeper).

started() ->
    _ = application:stop(seki),
    {ok, Keeper} = seki_registry_keeper:start_link(),
    Keeper.

stopped(Keeper) ->
    case whereis(seki_registry) =:= self() of
        true -> true = unregister(seki_registry);
        false -> true
    end,
    ok = gen_server:stop(Keeper),
    case ets:whereis(?TAB) of
        undefined -> true;
        _Held -> true = ets:delete(?TAB)
    end,
    ok.

become_registry() ->
    ok = wait_until(fun() -> whereis(seki_registry) =:= undefined end),
    true = register(seki_registry, self()),
    ok.

wait_until(Condition) ->
    wait_until(Condition, 200).

wait_until(_Condition, 0) ->
    timeout;
wait_until(Condition, Attempts) ->
    case Condition() of
        true ->
            ok;
        false ->
            timer:sleep(10),
            wait_until(Condition, Attempts - 1)
    end.
