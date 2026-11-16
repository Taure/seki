-module(seki_options).
-moduledoc false.

%% What a process or a limiter is created with is checked before anything is
%% started. A value of the wrong kind is refused there, where the caller sees
%% it, instead of bringing the process down the first time it is used. A key
%% that is not known is left alone.

-export([check/2, check/3]).

-type kind() ::
    pos_integer
    | percent
    | positive
    | boolean
    | atom
    | interval
    | options
    | {one_of, [atom()]}
    | {function, arity()}.
-type invalid() :: invalid_options | {invalid_option, atom()} | {missing_option, atom()}.

-export_type([kind/0, invalid/0]).

-spec check(term(), [{atom(), kind()}]) -> ok | {error, invalid()}.
check(Opts, Kinds) ->
    check(Opts, Kinds, []).

-spec check(term(), [{atom(), kind()}], [atom()]) -> ok | {error, invalid()}.
check(Opts, Kinds, Required) when is_map(Opts) ->
    Invalid = [
        Key
     || {Key, Kind} <- Kinds, is_map_key(Key, Opts), not is_valid(Kind, maps:get(Key, Opts))
    ],
    case {Invalid, [Key || Key <- Required, not is_map_key(Key, Opts)]} of
        {[Key | _], _Missing} -> {error, {invalid_option, Key}};
        {[], [Key | _]} -> {error, {missing_option, Key}};
        {[], []} -> ok
    end;
check(_Opts, _Kinds, _Required) ->
    {error, invalid_options}.

-spec is_valid(kind(), term()) -> boolean().
is_valid(pos_integer, Value) -> is_integer(Value) andalso Value > 0;
is_valid(percent, Value) -> is_number(Value) andalso Value > 0 andalso Value =< 100;
is_valid(positive, Value) -> is_number(Value) andalso Value > 0;
is_valid(boolean, Value) -> is_boolean(Value);
is_valid(atom, Value) -> is_atom(Value);
is_valid(interval, Value) -> is_integer(Value) andalso Value > 0 andalso Value =< 16#FFFFFFFF;
is_valid(options, Value) -> is_map(Value);
is_valid({one_of, Allowed}, Value) -> lists:member(Value, Allowed);
is_valid({function, Arity}, Value) -> is_function(Value, Arity).
