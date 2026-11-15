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
