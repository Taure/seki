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
