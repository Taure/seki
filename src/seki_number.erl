-module(seki_number).
-moduledoc false.

%% `max/2` and `min/2` are specified over any term, so the type checker
%% forgets what their result is. These keep the type of their arguments, and
%% return the same argument the BIFs do when the two compare equal.

-export([larger/2, smaller/2]).

-spec larger(Number, Number) -> Number.
larger(A, B) when A >= B -> A;
larger(_A, B) -> B.

-spec smaller(Number, Number) -> Number.
smaller(A, B) when A =< B -> A;
smaller(_A, B) -> B.
