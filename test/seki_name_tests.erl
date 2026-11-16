-module(seki_name_tests).

-include_lib("eunit/include/eunit.hrl").

-export([log/2]).

-define(LONGEST_LABEL, 1024).

an_atom_or_a_number_is_its_own_label_test() ->
    ?assertEqual(payments, seki_name:label(payments)),
    ?assertEqual(7, seki_name:label(7)),
    ?assertEqual(1.5, seki_name:label(1.5)).

a_short_binary_is_its_own_label_test() ->
    ?assertEqual(~"orders", seki_name:label(~"orders")),
    ?assertEqual(binary:copy(~"a", 255), seki_name:label(binary:copy(~"a", 255))).

a_binary_longer_than_an_atom_is_printed_short_test() ->
    Label = seki_name:label(binary:copy(~"a", 256)),
    ?assertMatch(<<"<<\"aaaa", _/binary>>, Label),
    ?assertEqual(~"\"...>>", binary:part(Label, byte_size(Label), -6)),
    ?assert(byte_size(Label) < 256).

a_name_is_printed_twenty_levels_deep_test() ->
    ?assertEqual(
        ~"[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19|...]",
        seki_name:label(lists:seq(1, 30))
    ),
    ?assertEqual(
        ~"[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]",
        seki_name:label(lists:seq(1, 19))
    ),
    ?assertEqual(~"{1,{2,{3,{4,{5,{6,{7,{8,{9,{10,...}}}}}}}}}}", seki_name:label(nested(30))),
    ?assertEqual(~"{1,{2,{3,{4,{5,{6,{7,{8,{9,[]}}}}}}}}}", seki_name:label(nested(9))).

chars_that_are_not_unicode_are_printed_again_test() ->
    NotUnicode = [${, 16#D800, $}],
    ?assertEqual(~"{tenant,<<\"å\">>}", seki_name:printed(NotUnicode, {tenant, ~"å"})),
    ?assertEqual(
        ~"[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19|...]",
        seki_name:printed(NotUnicode, lists:seq(1, 30))
    ),
    ?assertEqual(~"{tenant,<<\"å\"/utf8>>}", seki_name:printed("{tenant,<<\"å\"/utf8>>}", ignored)).

nested(Levels) ->
    nested(Levels, []).

nested(0, Inner) -> Inner;
nested(Level, Inner) -> nested(Level - 1, {Level, Inner}).

another_term_is_labelled_as_it_prints_test() ->
    ?assertEqual(~"{payments,<<\"t1\">>}", seki_name:label({payments, ~"t1"})),
    ?assertEqual(~"[shed,1]", seki_name:label([shed, 1])),
    ?assertEqual(~"{tenant,<<\"å\"/utf8>>}", seki_name:label({tenant, ~"å"})),
    ?assert(is_binary(seki_name:label({tenant, ~"日本"}))).

a_large_name_has_a_short_label_test_() ->
    [
        ?_assertMatch(
            Label when is_binary(Label) andalso byte_size(Label) =< ?LONGEST_LABEL,
            seki_name:label(Name)
        )
     || Name <:- [
            large(),
            {tenant, large()},
            lists:duplicate(100, large()),
            list_to_tuple(lists:duplicate(100, large())),
            #{large() => large()},
            lists:seq(1, 100_000),
            binary:copy(~"日本", 1000)
        ]
    ].

a_rejected_request_logs_a_short_name_test_() ->
    {foreach,
        fun() ->
            {ok, _} = application:ensure_all_started(seki),
            ok
        end,
        fun(_) ->
            _ = logger:remove_handler(?MODULE),
            application:stop(seki)
        end,
        [
            fun a_full_bulkhead_logs_a_short_name/0,
            fun a_load_shedder_logs_a_short_name/0,
            fun an_adaptive_limiter_logs_a_short_name/0,
            fun a_breaker_logs_a_short_name/0
        ]}.

a_full_bulkhead_logs_a_short_name() ->
    ok = listen(),
    Name = {bulkhead, large()},
    {ok, _} = seki:new_bulkhead(Name, #{max_concurrent => 1}),
    ok = seki_bulkhead:acquire(Name),
    {error, bulkhead_full} = seki_bulkhead:acquire(Name),
    ?assertMatch(#{msg := bulkhead_full, name := <<"{bulkhead,", _/binary>>}, logged()).

a_load_shedder_logs_a_short_name() ->
    ok = listen(),
    Name = {shed, large()},
    {ok, _} = seki:new_shed(Name, #{max_in_flight => 1}),
    ok = seki_shed:admit(Name),
    {error, shed} = seki_shed:admit(Name),
    ?assertMatch(#{msg := request_shed, name := <<"{shed,", _/binary>>}, logged()).

an_adaptive_limiter_logs_a_short_name() ->
    ok = listen(),
    Name = {adaptive, large()},
    {ok, _} = seki:new_adaptive(Name, #{initial_limit => 1}),
    ok = seki_adaptive:acquire(Name),
    {error, limit_reached} = seki_adaptive:acquire(Name),
    ?assertMatch(#{msg := adaptive_limit_reached, name := <<"{adaptive,", _/binary>>}, logged()).

a_breaker_logs_a_short_name() ->
    ok = listen(),
    Name = {breaker, large()},
    {ok, _} = seki:new_breaker(Name, #{window_size => 1, wait_duration => 60000}),
    {error, {error, boom, _}} = seki:call(Name, fun() -> error(boom) end),
    ?assertMatch(#{msg := breaker_call_raised, name := <<"{breaker,", _/binary>>}, logged()),
    ?assertMatch(#{msg := breaker_tripped, name := <<"{breaker,", _/binary>>}, logged()).

large() ->
    binary:copy(~"k", 1_000_000).

listen() ->
    logger:add_handler(?MODULE, ?MODULE, #{level => warning, config => #{pid => self()}}).

logged() ->
    receive
        {logged, #{msg := {report, #{name := Label} = Report}} = Event} ->
            ?assert(byte_size(Label) =< ?LONGEST_LABEL),
            ?assert(erlang:external_size(Event) =< 4 * ?LONGEST_LABEL),
            Report;
        {logged, Event} ->
            ?assert(erlang:external_size(Event) =< 4 * ?LONGEST_LABEL),
            logged()
    after 1000 -> nothing_logged
    end.

log(Event, #{config := #{pid := Pid}}) ->
    Pid ! {logged, Event},
    ok.
