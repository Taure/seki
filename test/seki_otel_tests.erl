-module(seki_otel_tests).

-include_lib("eunit/include/eunit.hrl").

name_attribute_test() ->
    ?assertEqual(payments, seki_otel:name_attribute(payments)),
    ?assertEqual(undefined, seki_otel:name_attribute(undefined)),
    ?assertEqual(~"orders", seki_otel:name_attribute(~"orders")),
    ?assertEqual(7, seki_otel:name_attribute(7)),
    ?assertEqual(~"{payments,<<\"t1\">>}", seki_otel:name_attribute({payments, ~"t1"})),
    ?assertEqual(~"{tenant,<<\"å\"/utf8>>}", seki_otel:name_attribute({tenant, ~"å"})).

a_large_name_is_a_short_attribute_test() ->
    Large = binary:copy(~"k", 1_000_000),
    ?assert(byte_size(seki_otel:name_attribute(Large)) =< 1024),
    ?assert(byte_size(seki_otel:name_attribute({tenant, Large})) =< 1024).

setup_attaches_one_handler_per_event_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    ok = seki_otel:setup(),
    ?assertEqual(lists:sort(handlers()), attached()),
    ok = seki_otel:teardown(),
    ?assertEqual([], attached()).

measurements_become_seki_attributes_test() ->
    ?assertEqual(
        #{
            'seki.remaining' => 1,
            'seki.cost' => 2,
            'seki.retry_after' => 3,
            'seki.count' => 4,
            'seki.system_time' => 5,
            'seki.attempt' => 6,
            'seki.attempts' => 7,
            'seki.delay' => 8,
            'seki.current' => 9,
            'seki.available' => 10
        },
        seki_otel:measurements_to_attrs(#{
            remaining => 1,
            cost => 2,
            retry_after => 3,
            count => 4,
            system_time => 5,
            attempt => 6,
            attempts => 7,
            delay => 8,
            current => 9,
            available => 10
        })
    ),
    ?assertEqual(#{}, seki_otel:measurements_to_attrs(#{})).

attached() ->
    Ids = [Id || {Id, _Event} <:- handlers()],
    lists:sort([
        {Id, Event}
     || #{id := Id, event_name := Event} <:- telemetry:list_handlers([seki]), lists:member(Id, Ids)
    ]).

handlers() ->
    [
        {seki_otel_seki_rate_limit_allow, [seki, rate_limit, allow]},
        {seki_otel_seki_rate_limit_deny, [seki, rate_limit, deny]},
        {seki_otel_seki_rate_limit_denied, [seki, rate_limit, denied]},
        {seki_otel_seki_breaker_state_change, [seki, breaker, state_change]},
        {seki_otel_seki_breaker_call, [seki, breaker, call]},
        {seki_otel_seki_retry_attempt, [seki, retry, attempt]},
        {seki_otel_seki_retry_retry, [seki, retry, retry]},
        {seki_otel_seki_retry_success, [seki, retry, success]},
        {seki_otel_seki_retry_exhausted, [seki, retry, exhausted]},
        {seki_otel_seki_bulkhead_acquire, [seki, bulkhead, acquire]},
        {seki_otel_seki_bulkhead_release, [seki, bulkhead, release]},
        {seki_otel_seki_bulkhead_rejected, [seki, bulkhead, rejected]}
    ].
