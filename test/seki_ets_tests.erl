-module(seki_ets_tests).

-include_lib("eunit/include/eunit.hrl").

-export([interfering_step/3, counting_step/1, keep_step/1]).

new_tab() ->
    ets:new(?MODULE, [set, public]).

update_applies_default_test() ->
    Tab = new_tab(),
    ?assertEqual({ok, 1}, seki_ets:update(Tab, counter, fun(V) when is_integer(V) -> V + 1 end, 0)),
    ?assertEqual({ok, 2}, seki_ets:update(Tab, counter, fun(V) when is_integer(V) -> V + 1 end, 0)),
    ?assertEqual([{counter, 2}], ets:lookup(Tab, counter)).

keep_does_not_write_test() ->
    Tab = new_tab(),
    ?assertEqual({ok, seen}, seki_ets:atomic_update(Tab, key, {?MODULE, keep_step, []})),
    ?assertEqual([], ets:lookup(Tab, key)).

contention_test() ->
    Tab = new_tab(),
    ?assertEqual(
        {error, contention},
        seki_ets:atomic_update(Tab, key, {?MODULE, interfering_step, [Tab, key]})
    ).

update_raises_on_contention_test() ->
    Tab = new_tab(),
    true = ets:insert(Tab, {key, 0}),
    ?assertError(
        {contention, key},
        seki_ets:update(
            Tab,
            key,
            fun(V) ->
                ets:insert(Tab, {key, make_ref()}),
                V
            end,
            0
        )
    ).

non_literal_keys_test_() ->
    [
        {lists:flatten(io_lib:format("~0p", [Key])), fun() -> non_literal_key(Key) end}
     || Key <:- ['_', '$1', {a, '_'}, [x, '$2'], #{a => 1}, '']
    ].

non_literal_key(Key) ->
    Tab = new_tab(),
    Others = [{other, 0}, {{a, b}, 0}, {[x, y], 0}, {#{a => 1, b => 2}, 0}, {'$1x', 0}],
    _ = [ok = seki_ets:insert(Tab, K, V) || {K, V} <:- Others],
    Step = {?MODULE, counting_step, []},
    ?assertEqual({ok, 1}, seki_ets:atomic_update(Tab, Key, Step)),
    ?assertEqual({ok, 2}, seki_ets:atomic_update(Tab, Key, Step)),
    ?assertEqual({ok, 2}, seki_ets:lookup(Tab, Key)),
    ?assertEqual([{ok, V} || {_, V} <:- Others], [seki_ets:lookup(Tab, K) || {K, _} <:- Others]).

non_literal_values_test() ->
    Tab = new_tab(),
    Values = ['_', '$1', #{a => 1}, {x, '_'}, #{a => 1, b => 2}, 1.0, 1],
    [
        ?assertEqual({ok, V}, seki_ets:update(Tab, key, fun(_) -> V end, undefined))
     || V <:- Values
    ],
    ?assertEqual([{key, 1}], ets:lookup(Tab, key)).

stale_value_is_not_replaced_test() ->
    Tab = new_tab(),
    true = ets:insert(Tab, {key, #{a => 1, b => 2}}),
    ?assertEqual(
        {error, contention},
        seki_ets:atomic_update(Tab, key, {?MODULE, interfering_step, [Tab, key]})
    ),
    [{key, Value}] = ets:lookup(Tab, key),
    ?assert(is_reference(Value)).

cleanup_deletes_only_stale_entries_test() ->
    Tab = new_tab(),
    Now = erlang:monotonic_time(millisecond),
    Old = Now - 10000,
    true = ets:insert(Tab, [
        {stale_window, {1, 2, Old}},
        {stale_bucket, {1.0, Old}},
        {fresh_window, {1, 2, Now}},
        {fresh_bucket, {1.0, Now}},
        {tat, Old}
    ]),
    ok = seki_ets:cleanup(Tab, 5000),
    ?assertEqual(
        [fresh_bucket, fresh_window, tat], lists:sort([K || {K, _} <:- ets:tab2list(Tab)])
    ).

keep_step(_Current) ->
    {seen, keep}.

counting_step(not_found) ->
    {1, {write, 1}};
counting_step({ok, N}) ->
    {N + 1, {write, N + 1}}.

interfering_step(_Current, Tab, Key) ->
    true = ets:insert(Tab, {Key, make_ref()}),
    {ok, {write, mine}}.
