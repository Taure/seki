-module(seki_options_tests).

-include_lib("eunit/include/eunit.hrl").

-define(KINDS, [
    {size, pos_integer},
    {share, percent},
    {ratio, positive},
    {enabled, boolean},
    {kind, {one_of, [count, time]}},
    {classifier, {function, 1}},
    {backend, module},
    {nested, options}
]).

options_of_the_right_kind_pass_test_() ->
    [
        ?_assertEqual(ok, seki_options:check(Opts, ?KINDS))
     || Opts <:- [
            #{},
            #{unknown => whatever},
            #{size => 1},
            #{size => 1 bsl 80},
            #{share => 1},
            #{share => 100},
            #{share => 0.5},
            #{ratio => 0.001},
            #{ratio => 7},
            #{enabled => true},
            #{enabled => false},
            #{kind => count},
            #{kind => time},
            #{classifier => fun erlang:is_atom/1},
            #{backend => seki_backend_ets},
            #{nested => #{}},
            #{size => 5, share => 50, kind => time, enabled => true}
        ]
    ].

an_option_of_the_wrong_kind_is_named_test_() ->
    [
        ?_assertEqual({error, {invalid_option, Key}}, seki_options:check(#{Key => Value}, ?KINDS))
     || {Key, Value} <:- [
            {size, 0},
            {size, -1},
            {size, 1.0},
            {size, infinity},
            {share, 0},
            {share, 100.5},
            {share, 101},
            {share, half},
            {ratio, 0},
            {ratio, -0.5},
            {ratio, ~"0.5"},
            {enabled, yes},
            {enabled, 1},
            {kind, bogus},
            {kind, ~"count"},
            {classifier, fun erlang:is_map_key/2},
            {classifier, not_a_fun},
            {backend, ~"seki_backend_ets"},
            {nested, []}
        ]
    ].

the_first_wrong_option_is_named_test() ->
    ?assertEqual(
        {error, {invalid_option, size}},
        seki_options:check(#{size => 0, kind => bogus, share => 50}, ?KINDS)
    ),
    ?assertEqual(
        {error, {invalid_option, kind}},
        seki_options:check(#{size => 1, kind => bogus, nested => []}, ?KINDS)
    ).

anything_but_a_map_is_refused_test_() ->
    [
        ?_assertEqual({error, invalid_options}, seki_options:check(Opts, ?KINDS))
     || Opts <:- [[], [{size, 1}], undefined, ~"options"]
    ].

a_required_option_must_be_there_test() ->
    ?assertEqual(ok, seki_options:check(#{size => 1, share => 5}, ?KINDS, [size, share])),
    ?assertEqual(
        {error, {missing_option, share}}, seki_options:check(#{size => 1}, ?KINDS, [size, share])
    ),
    ?assertEqual({error, {missing_option, size}}, seki_options:check(#{}, ?KINDS, [size, share])),
    ?assertEqual(
        {error, {invalid_option, size}}, seki_options:check(#{size => 0}, ?KINDS, [size, share])
    ),
    ?assertEqual({error, invalid_options}, seki_options:check([], ?KINDS, [size])).
