-module(seki_name).
-moduledoc false.

%% A name as it goes into a log line or a span attribute. An atom is at most
%% 255 characters long, but any other term is as large as whoever made it
%% likes, and a rejected request logs it every time. Such a name is printed
%% to a limited depth.

-export([label/1, printed/2]).

-define(DEPTH, 20).
-define(LONGEST_BINARY, 255).

-spec label(seki:name()) -> atom() | number() | binary().
label(Name) when is_atom(Name); is_number(Name) ->
    Name;
label(Name) when is_binary(Name), byte_size(Name) =< ?LONGEST_BINARY ->
    Name;
label(Name) ->
    printed(io_lib:format("~0tP", [Name, ?DEPTH]), Name).

%% `Chars` is what `~tP` made of the name. Should they ever hold something
%% that is not Unicode, the name is printed again without `t`, which escapes
%% whatever is not Latin-1.
-spec printed(io_lib:chars(), seki:name()) -> binary().
printed(Chars, Name) ->
    case unicode:characters_to_binary(Chars) of
        Printed when is_binary(Printed) -> Printed;
        _NotUnicode -> iolist_to_binary(io_lib:format("~0P", [Name, ?DEPTH]))
    end.
