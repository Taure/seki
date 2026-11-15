-module(seki_number_tests).

-include_lib("eunit/include/eunit.hrl").

-define(NUMBERS, [-3, -1.5, -0.0, 0, 0.0, 1, 1.0, 2, 2.5, 1 bsl 80, 1.0e300]).

larger_is_max_test() ->
    [?assert(seki_number:larger(A, B) =:= max(A, B)) || A <:- ?NUMBERS, B <:- ?NUMBERS].

smaller_is_min_test() ->
    [?assert(seki_number:smaller(A, B) =:= min(A, B)) || A <:- ?NUMBERS, B <:- ?NUMBERS].
